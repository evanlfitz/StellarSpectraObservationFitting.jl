# using LineSearches
using ParameterHandling
using Optim
using Nabla
import Base.show

# χ² loss function
_loss(tel, star, rv, d::GenericData) =
    sum(((total_model(tel, star, rv) .- d.flux) .^ 2) ./ d.var)
# χ² loss function broadened by an lsf at each time (about 2x slower)
# _loss(tel::AbstractMatrix, star::AbstractMatrix, rv::AbstractMatrix, d::LSFData) =
#     mapreduce(i -> sum((((d.lsf[i] * (view(tel, :, i) .* (view(star, :, i) .+ view(rv, :, i)))) .- view(d.flux, :, i)) .^ 2) ./ view(d.var, :, i)), +, 1:size(tel, 2))
_loss(tel, star, rv, d::LSFData) =
    sum((((d.lsf * total_model(tel, star, rv)) .- d.flux) .^ 2) ./ d.var)
function loss(o::Output, om::OrderModel, d::Data;
	tel=om.tel.lm, star=om.star.lm, rv=om.rv.lm,
	recalc_tel::Bool=true, recalc_star::Bool=true, recalc_rv::Bool=true)

    recalc_tel ? tel_o = spectra_interp(_eval_lm(tel), om.t2o) : tel_o = o.tel
    recalc_star ? star_o = spectra_interp(_eval_lm(star), om.b2o) : star_o = o.star
    recalc_rv ? rv_o = spectra_interp(_eval_lm(rv), om.b2o) : rv_o = o.rv
    return _loss(tel_o, star_o, rv_o, d)
end

possible_θ = Union{Vector{<:Vector{<:AbstractArray}}, AbstractMatrix}

function loss_funcs_telstar(o::Output, om::OrderModel, d::Data)
    l(; kwargs...) = loss(o, om, d; kwargs...)

    l_telstar(telstar; kwargs...) =
        loss(o, om, d; tel=telstar[1], star=telstar[2], recalc_rv=false, kwargs...) +
			model_prior(telstar[1], om.reg_tel) + model_prior(telstar[2], om.reg_star)
    function l_telstar_s(telstar_s)
		recalc_tel = !(typeof(om.tel.lm) <: TemplateModel)
		recalc_star = !(typeof(om.tel.lm) <: TemplateModel)
		recalc_tel ? tel = [om.tel.lm.M, telstar_s[1], om.tel.lm.μ] : tel = om.tel.lm
		recalc_star ? star = [om.star.lm.M, telstar_s[2], om.star.lm.μ] : star = om.star.lm
		return loss(o, om, d; tel=tel, star=star, recalc_rv=false, recalc_tel=recalc_tel, recalc_star=recalc_star) +
			model_prior(tel, om.reg_tel) + model_prior(star, om.reg_star)
    end

    l_rv(rv_s) = loss(o, om, d; rv=[om.rv.lm.M, rv_s], recalc_tel=false, recalc_star=false)

    return l, l_telstar, l_telstar_s, l_rv
end

α, β1, β2, ϵ = 1e-3, 0.9, 0.999, 1e-8
mutable struct Adam{T<:AbstractArray}
    α::Float64
    β1::Float64
    β2::Float64
    m::T
    v::T
    β1_acc::Float64
    β2_acc::Float64
    ϵ::Float64
end
Adam(θ0::AbstractArray, α::Float64, β1::Float64, β2::Float64, ϵ::Float64) =
    Adam(α, β1, β2, vector_zero(θ0), vector_zero(θ0), β1, β2, ϵ)
Adam(θ0::AbstractArray; α::Float64=α, β1::Float64=β1, β2::Float64=β2, ϵ::Float64=ϵ) =
	Adam(θ0, α, β1, β2, ϵ)

mutable struct AdamState
    iter::Int
    ℓ::Float64
    L1_Δ::Float64
    L2_Δ::Float64
    L∞_Δ::Float64
	δ_ℓ::Float64
	δ_L1_Δ::Float64
	δ_L2_Δ::Float64
	δ_L∞_Δ::Float64
end
AdamState() = AdamState(0, 0., 0., 0., 0., 0., 0., 0., 0.)
function show(io::IO, as::AdamState)
    println("Iter:  ", as.iter)
    println("ℓ:     ", as.ℓ,    "  ℓ_$(as.iter)/ℓ_$(as.iter-1):       ", as.δ_ℓ)
	println("L2_Δ:  ", as.L2_Δ, "  L2_Δ_$(as.iter)/L2_Δ_$(as.iter-1): ", as.δ_L2_Δ)
	println()
end

function _iterate_helper!(θ::AbstractArray{Float64}, ∇θ::AbstractArray{Float64}, opt::Adam; m=opt.m, v=opt.v, α=opt.α, β1=opt.β1, β2=opt.β2, ϵ=opt.ϵ, β1_acc=opt.β1_acc, β2_acc=opt.β2_acc)
    # the matrix and dotted version is slower
    @inbounds for n in eachindex(θ)
        m[n] = β1 * m[n] + (1.0 - β1) * ∇θ[n]
        v[n] = β2 * v[n] + (1.0 - β2) * ∇θ[n]^2
        m̂ = m[n] / (1 - β1_acc)
        v̂ = v[n] / (1 - β2_acc)
        θ[n] -= α * m̂ / (sqrt(v̂) + ϵ)
    end
end
# this is slightly slower
# function iterate!(θs::Vector{<:Vector{<:AbstractArray{<:Real}}}, ∇θs::Vector{<:Vector{<:AbstractArray{<:Real}}}, opts::Vector{Vector{Adam}})
#     for i in eachindex(θs)
#         for j in eachindex(θs[i])
#             _iterate_helper!(θs[i][j], ∇θs[i][j], opts[i][j])
#             opt.β1_acc *= opt.β1
#             opt.β2_acc *= opt.β2
#         end
#     end
# end
function iterate!(θs::Vector{<:Vector{<:AbstractArray{<:Real}}}, ∇θs::Vector{<:Vector{<:AbstractArray{<:Real}}}, opt::Adam)
    for i in eachindex(θs)
        for j in eachindex(θs[i])
            _iterate_helper!(θs[i][j], ∇θs[i][j], opt; m=opt.m[i][j], v=opt.v[i][j])
        end
    end
    opt.β1_acc *= opt.β1
    opt.β2_acc *= opt.β2
end
function iterate!(θ::AbstractVecOrMat{<:Real}, ∇θ::AbstractVecOrMat{<:Real}, opt::Adam)
	_iterate_helper!(θ, ∇θ, opt; m=opt.m, v=opt.v)
    opt.β1_acc *= opt.β1
    opt.β2_acc *= opt.β2
end

L∞_cust(Δ) = maximum([maximum([maximum(i) for i in j]) for j in Δ])
function AdamState!_helper(as::AdamState, f::Symbol, val)
	setfield!(as, Symbol(:δ_,f), val / getfield(as, f))
	setfield!(as, f, val)
end
function AdamState!(as::AdamState, ℓ, Δ)
	as.iter += 1
	AdamState!_helper(as, :ℓ, ℓ)
	flat_Δ = Iterators.flatten(Iterators.flatten(Δ))
	AdamState!_helper(as, :L1_Δ, sum(abs, flat_Δ))
	AdamState!_helper(as, :L2_Δ, sum(abs2, flat_Δ))
	AdamState!_helper(as, :L∞_Δ, L∞_cust(Δ))
end

_print_stuff_def = false
_iter_def = 100
_f_tol_def = 1e-3
_g_tol_def = 1e-3

struct AdamWorkspace{T}
	θ::T
	opt::Adam
	as::AdamState
	l::Function
	function AdamWorkspace(θ::T, opt, as, l) where T
		@assert typeof(l(θ)) <: Real
		return new{T}(θ, opt, as, l)
	end
end
AdamWorkspace(θ, l::Function) = AdamWorkspace(θ, Adam(θ), AdamState(), l)

function update!(aws::AdamWorkspace)
    val, Δ = ∇(aws.l; get_output=true)(aws.θ)
	Δ = only(Δ)
	AdamState!(aws.as, val.val, Δ)
    iterate!(aws.θ, Δ, aws.opt)
end

check_converged(as::AdamState, f_tol::Real, g_tol::Real) = (max(as.δ_ℓ, 1/as.δ_ℓ) < (1 + abs(f_tol))) && (max(as.δ_L2_Δ,1/as.δ_L2_Δ) < (1+abs(g_tol)))
check_converged(as::AdamState, iter::Int, f_tol::Real, g_tol::Real) = (as.iter > iter) || check_converged(as, f_tol, g_tol)
function train_SubModel!(aws::AdamWorkspace; iter=_iter_def, f_tol = _f_tol_def, g_tol = _g_tol_def, cb::Function=()->(), kwargs...)
	converged = false  # check_converged(aws.as, iter, f_tol, g_tol)
	while !converged
		update!(aws)
		cb()
		converged = check_converged(aws.as, iter, f_tol, g_tol)
	end
	converged = check_converged(aws.as, f_tol, g_tol)
	converged ? println("Converged") : println("Max Iters Reached")
	return converged
end
function default_cb(as::AdamState; print_stuff=_print_stuff_def)
	if print_stuff
		return () -> println(as)
	else
		return () -> ()
	end
end

abstract type ModelWorkspace end

struct TelStarWorkspace <: ModelWorkspace
	telstar::AdamWorkspace
	rv::AdamWorkspace
	om::OrderModel
	o::Output
	d::Data
	only_s::Bool
end
function TelStarWorkspace(o::Output, om::OrderModel, d::Data; only_s::Bool=false)
	loss, loss_telstar, loss_telstar_s, loss_rv = loss_funcs_telstar(o, om, d)
	only_s ?
		telstar = AdamWorkspace([om.tel.lm.s, om.star.lm.s], loss_telstar_s) :
		telstar = AdamWorkspace([vec(om.tel.lm), vec(om.star.lm)], loss_telstar)
	rv = AdamWorkspace(om.rv.lm.s, loss_rv)
	return ModelWorkspace(telstar, rv, om, o, d, only_s)
end

function train_OrderModel!(mw::TelStarWorkspace; train_telstar::Bool=true, ignore_regularization::Bool=false, print_stuff::Bool=_print_stuff_def, kwargs...)

    if ignore_regularization
        reg_tel_holder = copy(mw.om.reg_tel)
        reg_star_holder = copy(mw.om.reg_star)
        zero_regularization(mw.om)
    end

    if train_telstar
		cb_telstar = default_cb(mw.telstar.as; print_stuff)
		result_telstar = train_SubModel!(mw.telstar; cb=cb_telstar, kwargs...)
		mw.telstar.as.iter = 0
        mw.o.star .= star_model(mw.om)
        mw.o.tel .= tel_model(mw.om)
    end
	mw.om.rv.lm.M .= calc_doppler_component_RVSKL(mw.om.star.λ, mw.om.star.lm.μ)
	cb_rv = default_cb(mw.rv.as; print_stuff)
	result_rv = train_SubModel!(mw.rv; cb=cb_rv, kwargs...)
    mw.rv.as.iter = 0
	mw.o.rv .= rv_model(mw.om)
	recalc_total!(mw.o, mw.d)

    if ignore_regularization
        copy_dict!(reg_tel_holder, mw.om.reg_tel)
        copy_dict!(reg_star_holder, mw.om.reg_star)
    end
	return result_telstar, result_rv
end


## Optim Versions

function opt_funcs(loss::Function, pars::possible_θ)
    flat_initial_params, unflatten = flatten(pars)  # unflatten returns Vector of untransformed params
    f = loss ∘ unflatten
    function g!(G, θ)
		θunfl = unflatten(θ)
        G[:], _ = flatten(∇(loss)(θunfl))
    end
    function fg_obj!(G, θ)
		θunfl = unflatten(θ)
		l, g = ∇(loss; get_output=true)(θunfl)
		G[:], _= flatten(g)
        return l.val
    end
    return flat_initial_params, OnceDifferentiable(f, g!, fg_obj!, flat_initial_params), unflatten
end

struct OptimSubWorkspace
    θ::possible_θ
    obj::OnceDifferentiable
    opt::Optim.FirstOrderOptimizer
    p0::Vector
    unflatten::Function
end
function OptimSubWorkspace(θ::possible_θ, loss::Function; use_cg::Bool=true)
	p0, obj, unflatten = opt_funcs(loss, θ)
	# opt = LBFGS(alphaguess = LineSearches.InitialHagerZhang(α0=NaN))
	# use_cg ? opt = ConjugateGradient() : opt = LBFGS()
	opt = LBFGS()
	# initial_state(method::LBFGS, ...) doesn't use the options for anything
	return OptimSubWorkspace(θ, obj, opt, p0, unflatten)
end

struct OptimWorkspace
    telstar::OptimSubWorkspace
    rv::OptimSubWorkspace
    om::OrderModel
    o::Output
    d::Data
    only_s::Bool
end
function OptimWorkspace(om::OrderModel, o::Output, d::Data; return_loss_f::Bool=false, only_s::Bool=false)
	loss, loss_telstar, loss_telstar_s, loss_rv = loss_funcs_telstar(o, om, d)
	rv = OptimSubWorkspace(om.rv.lm.s, loss_rv; use_cg=true)
	only_s ?
		telstar = OptimSubWorkspace([om.tel.lm.s, om.star.lm.s], loss_telstar_s; use_cg=!only_s) :
		telstar = OptimSubWorkspace([vec(om.tel.lm), vec(om.star.lm)], loss_telstar; use_cg=!only_s)
	ow = OptimWorkspace(telstar, rv, om, o, d, only_s)
	if return_loss_f
		return ow, loss
	else
		return ow
	end
end
OptimWorkspace(om::OrderModel, d::Data, inds::AbstractVecOrMat; kwargs...) =
	OptimWorkspace(om(inds), d(inds); kwargs...)
OptimWorkspace(om::OrderModel, d::Data; kwargs...) =
	OptimWorkspace(om, Output(om, d), d; kwargs...)

function _OSW_optimize!(osw::OptimSubWorkspace, options::Optim.Options)
    result = Optim.optimize(osw.obj, osw.p0, osw.opt, options)
    osw.p0[:] = result.minimizer
    return result
end

# ends optimization if true
function optim_cb(x::OptimizationState; print_stuff::Bool=true)
    if print_stuff
        println()
        if x.iteration > 0
            println("Iter:  ", x.iteration)
            println("Time:  ", x.metadata["time"], " s")
            println("ℓ:     ", x.value)
            println("l∞(∇): ", x.g_norm)
            println()
        end
    end
    return false
end


_print_stuff_def = false
_iter_def = 100
_f_tol_def = 1e-6
_g_tol_def = 400

function train_OrderModel!(ow::OptimWorkspace; print_stuff::Bool=_print_stuff_def, iterations::Int=_iter_def, f_tol::Real=_f_tol_def, g_tol::Real=_g_tol_def*sqrt(length(ow.telstar.p0)), train_telstar::Bool=true, ignore_regularization::Bool=false, kwargs...)
    optim_cb_local(x::OptimizationState) = optim_cb(x; print_stuff=print_stuff)

    if ignore_regularization
        reg_tel_holder = copy(ow.om.reg_tel)
        reg_star_holder = copy(ow.om.reg_star)
        zero_regularization(ow.om)
    end

    if train_telstar
        options = Optim.Options(;iterations=iterations, f_tol=f_tol, g_tol=g_tol, callback=optim_cb_local, kwargs...)
        # optimize tellurics and star
        result_telstar = _OSW_optimize!(ow.telstar, options)
		lm_vec = ow.telstar.unflatten(ow.telstar.p0)
        if ow.only_s
			ow.om.tel.lm.s[:] = lm_vec[1]
			ow.om.star.lm.s[:] = lm_vec[2]
        else
            copy_to_LinearModel!(ow.om.tel.lm, lm_vec[1])
			copy_to_LinearModel!(ow.om.star.lm, lm_vec[2])
        end
        ow.o.star .= star_model(ow.om)
        ow.o.tel .= tel_model(ow.om)
    end

    # optimize RVs
    options = Optim.Options(;callback=optim_cb_local, g_tol=g_tol*sqrt(length(ow.rv.p0) / length(ow.telstar.p0)), kwargs...)
    ow.om.rv.lm.M .= calc_doppler_component_RVSKL(ow.om.star.λ, ow.om.star.lm.μ)
    result_rv = _OSW_optimize!(ow.rv, options)
	ow.om.rv.lm.s[:] = ow.rv.unflatten(ow.rv.p0)
    ow.o.rv .= rv_model(ow.om)
	recalc_total!(ow.o, ow.d)

    if ignore_regularization
        copy_dict!(reg_tel_holder, ow.om.reg_tel)
        copy_dict!(reg_star_holder, ow.om.reg_star)
    end
    return result_telstar, result_rv
end

function train_OrderModel!(ow::OptimWorkspace, n::Int; kwargs...)
    for i in 1:n
        train_OrderModel!(ow; kwargs...)
    end
end

function fine_train_OrderModel!(ow::OptimWorkspace; g_tol::Real=_g_tol_def*sqrt(length(ow.telstar.p0)), kwargs...)
    train_OrderModel!(ow; kwargs...)  # 16s
    return train_OrderModel!(ow; g_tol=g_tol/10, f_tol=1e-8, kwargs...)
end
