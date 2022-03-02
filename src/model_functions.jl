using AbstractGPs
using LinearAlgebra
using KernelFunctions
using TemporalGPs
import AbstractGPs
using Distributions
import Base.copy
import Base.vec
import Base.getindex
import Base.eachindex
import Base.setindex!
using SparseArrays
using SpecialFunctions
using StaticArrays
using Nabla

abstract type Data end

_current_matrix_modifier = SparseMatrixCSC

struct LSFData{T<:Number, AM<:AbstractMatrix{T}, M<:Matrix{<:Number}} <: Data
    flux::AM
    var::AM
    log_λ_obs::AM
	log_λ_obs_bounds::M
    log_λ_star::AM
	log_λ_star_bounds::M
	lsf::_current_matrix_modifier
	function LSFData(flux::AM, var::AM, log_λ_obs::AM, log_λ_star::AM, lsf::_current_matrix_modifier) where {T<:Real, AM<:AbstractMatrix{T}}
		@assert size(flux) == size(var) == size(log_λ_obs) == size(log_λ_star)
		@assert size(lsf, 1) == size(lsf, 2) == size(flux, 1)
		log_λ_obs_bounds = bounds_generator(log_λ_obs)
		log_λ_star_bounds = bounds_generator(log_λ_star)
		return new{T, AM, typeof(log_λ_obs_bounds)}(flux::AM, var::AM, log_λ_obs::AM, log_λ_obs_bounds, log_λ_star, log_λ_star_bounds, lsf)
	end
end
(d::LSFData)(inds::AbstractVecOrMat) =
	LSFData(view(d.flux, :, inds), view(d.var, :, inds),
	view(d.log_λ_obs, :, inds), view(d.log_λ_star, :, inds), d.lsf)
Base.copy(d::LSFData) = LSFData(copy(d.flux), copy(d.var), copy(d.log_λ_obs), copy(d.log_λ_star), copy(d.lsf))

struct GenericData{T<:Number, AM<:AbstractMatrix{T}, M<:Matrix{<:Number}} <: Data
    flux::AM
    var::AM
    log_λ_obs::AM
	log_λ_obs_bounds::M
    log_λ_star::AM
	log_λ_star_bounds::M
	function GenericData(flux::AM, var::AM, log_λ_obs::AM, log_λ_star::AM) where {T<:Number, AM<:AbstractMatrix{T}}
		@assert size(flux) == size(var) == size(log_λ_obs) == size(log_λ_star)
		log_λ_obs_bounds = bounds_generator(log_λ_obs)
		log_λ_star_bounds = bounds_generator(log_λ_star)
		return new{T, AM, typeof(log_λ_obs_bounds)}(flux, var, log_λ_obs, log_λ_obs_bounds, log_λ_star, log_λ_star_bounds)
	end
end
(d::GenericData)(inds::AbstractVecOrMat) =
	GenericData(view(d.flux, :, inds), view(d.var, :, inds),
	view(d.log_λ_obs, :, inds), view(d.log_λ_star, :, inds))
Base.copy(d::GenericData) = GenericData(copy(d.flux), copy(d.var), copy(d.log_λ_obs), copy(d.log_λ_star))
GenericData(d::LSFData) = GenericData(d.flux, d.var, d.log_λ_obs, d.log_λ_star)
GenericData(d::GenericData) = d

function create_λ_template(log_λ_obs::AbstractMatrix; upscale::Real=2*sqrt(2))
    log_min_wav, log_max_wav = extrema(log_λ_obs)
    Δ_logλ_og = minimum(view(log_λ_obs, size(log_λ_obs, 1), :) .- view(log_λ_obs, 1, :)) / size(log_λ_obs, 1)
	Δ_logλ = Δ_logλ_og / upscale
    log_λ_template = (log_min_wav - 2 * Δ_logλ_og):Δ_logλ:(log_max_wav + 2 * Δ_logλ_og)
    λ_template = exp.(log_λ_template)
    return log_λ_template, λ_template
end

abstract type LinearModel end

# Full (includes mean) linear model
struct FullLinearModel{T<:Number, AM1<:AbstractMatrix{T}, AM2<:AbstractMatrix{T}, AV<:AbstractVector{T}}  <: LinearModel
	M::AM1
	s::AM2
	μ::AV
	function FullLinearModel(M::AM1, s::AM2, μ::AV) where {T<:Number, AM1<:AbstractMatrix{T}, AM2<:AbstractMatrix{T}, AV<:AbstractVector{T}}
		@assert length(μ) == size(M, 1)
		@assert size(M, 2) == size(s, 1)
		return new{T, AM1, AM2, AV}(M, s, μ)
	end
end
Base.copy(flm::FullLinearModel) = FullLinearModel(copy(flm.M), copy(flm.s), copy(flm.μ))
LinearModel(flm::FullLinearModel, inds::AbstractVecOrMat) =
	FullLinearModel(flm.M, view(flm.s, :, inds), flm.μ)

# Base (no mean) linear model
struct BaseLinearModel{T<:Number, AM1<:AbstractMatrix{T}, AM2<:AbstractMatrix{T}} <: LinearModel
	M::AM1
	s::AM2
	function BaseLinearModel(M::AM1, s::AM2) where {T<:Number, AM1<:AbstractMatrix{T}, AM2<:AbstractMatrix{T}}
		@assert size(M, 2) == size(s, 1)
		return new{T, AM1, AM2}(M, s)
	end
end
Base.copy(blm::BaseLinearModel) = BaseLinearModel(copy(blm.M), copy(blm.s))
LinearModel(blm::BaseLinearModel, inds::AbstractVecOrMat) =
	BaseLinearModel(blm.M, view(blm.s, :, inds))

# Template (no bases) model
struct TemplateModel{T<:Number, AV<:AbstractVector{T}} <: LinearModel
	μ::AV
	n::Int
end
Base.copy(tlm::TemplateModel) = TemplateModel(copy(tlm.μ), tlm.n)
LinearModel(tm::TemplateModel, inds::AbstractVecOrMat) = TemplateModel(tm.μ, length(inds))

Base.getindex(lm::LinearModel, s::Symbol) = getfield(lm, s)
Base.eachindex(lm::T) where {T<:LinearModel} = fieldnames(T)
Base.setindex!(lm::LinearModel, a::AbstractVecOrMat, s::Symbol) = (lm[s] .= a)
vec(lm::LinearModel) = [lm[i] for i in eachindex(lm)]
vec(lm::TemplateModel) = [lm.μ]
vec(lms::Vector{<:LinearModel}) = [vec(lm) for lm in lms]

LinearModel(M::AbstractMatrix, s::AbstractMatrix, μ::AbstractVector) = FullLinearModel(M, s, μ)
LinearModel(M::AbstractMatrix, s::AbstractMatrix) = BaseLinearModel(M, s)
LinearModel(μ::AbstractVector, n::Int) = TemplateModel(μ, n)

LinearModel(lm::FullLinearModel, s::AbstractMatrix) = FullLinearModel(lm.M, s, lm.μ)
LinearModel(lm::BaseLinearModel, s::AbstractMatrix) = BaseLinearModel(lm.M, s)
LinearModel(lm::TemplateModel, s::AbstractMatrix) = lm

# Ref(lm::FullLinearModel) = [Ref(lm.M), Ref(lm.s), Ref(lm.μ)]
# Ref(lm::BaseLinearModel) = [Ref(lm.M), Ref(lm.s)]
# Ref(lm::TemplateModel) = [Ref(lm.μ)]

# _eval_lm(μ, n::Int) = repeat(μ, 1, n)
_eval_lm(μ, n::Int) = μ * ones(n)'  # this is faster I dont know why
_eval_lm(M, s) = M * s
_eval_lm(M, s, μ) =
	_eval_lm(M, s) .+ μ

_eval_lm(flm::FullLinearModel) = _eval_lm(flm.M, flm.s, flm.μ)
_eval_lm(blm::BaseLinearModel) = _eval_lm(blm.M, blm.s)
_eval_lm(tlm::TemplateModel) = _eval_lm(tlm.μ, tlm.n)
(lm::LinearModel)() = _eval_lm(lm)

(flm::FullLinearModel)(inds::AbstractVecOrMat) = _eval_lm(view(flm.M, inds, :), flm.s, flm.μ)
(blm::BaseLinearModel)(inds::AbstractVecOrMat) = _eval_lm(view(blm.M, inds, :), blm.s)
(tlm::TemplateModel)(inds::AbstractVecOrMat) = repeat(view(tlm.μ, inds), 1, tlm.n)

function copy_to_LinearModel!(to::LinearModel, from::LinearModel)
	@assert typeof(to)==typeof(from)
	if typeof(to) <: TemplateModel
		to.μ .= from.μ
	else
		for i in fieldnames(typeof(from))
			getfield(to, i) .= getfield(from, i)
		end
	end
end
function copy_to_LinearModel!(to::LinearModel, from::Vector)
	fns = fieldnames(typeof(to))
	if typeof(to) <: TemplateModel
		if typeof(from) <: Vector{<:Real}
			to.μ .= from
		else
			@assert length(from) == 1
			to.μ .= from[1]
		end
	else
		@assert length(from) == length(fns)
		for i in eachindex(fns)
			getfield(to, fns[i]) .= from[i]
		end
	end
end

struct Submodel{T<:Number, AV1<:AbstractVector{T}, AV2<:AbstractVector{T}, AA<:AbstractArray{T}}
    log_λ::AV1
    λ::AV2
	lm::LinearModel
	A_sde::StaticMatrix
	Σ_sde::StaticMatrix
	Δℓ_coeff::AA
end
const _acceptable_types = [:star, :tel]
function Submodel(log_λ_obs::AbstractVecOrMat, n_comp::Int; include_mean::Bool=true, type=:star, kwargs...)
	@assert type in _acceptable_types
	n_obs = size(log_λ_obs, 2)
	log_λ, λ = create_λ_template(log_λ_obs; kwargs...)
	len = length(log_λ)
	if include_mean
		lm = FullLinearModel(zeros(len, n_comp), zeros(n_comp, n_obs), ones(len))
	else
		lm = BaseLinearModel(zeros(len, n_comp), zeros(n_comp, n_obs))
	end
	if type == :star
		A_sde, Σ_sde = SOAP_gp_sde_prediction_matrices(step(log_λ))
		sparsity = Int(round(0.5 / (step(log_λ) * SOAP_gp_params.λ)))
	elseif type == :tel
		A_sde, Σ_sde = LSF_gp_sde_prediction_matrices(step(log_λ))
		sparsity = Int(round(0.5 / (step(log_λ) * LSF_gp_params.λ)))
	end
	Δℓ_coeff = gp_Δℓ_coefficients(length(log_λ), A_sde, Σ_sde; sparsity=sparsity)
	return Submodel(log_λ, λ, lm, A_sde, Σ_sde, Δℓ_coeff)
end
function Submodel(log_λ::AV1, λ::AV2, lm, A_sde::StaticMatrix, Σ_sde::StaticMatrix, Δℓ_coeff::AA) where {T<:Number, AV1<:AbstractVector{T}, AV2<:AbstractVector{T}, AA<:AbstractArray{T}}
	if typeof(lm) <: TemplateModel
		@assert length(log_λ) == length(λ) == length(lm.μ) == size(Δℓ_coeff, 1) == size(Δℓ_coeff, 2)
	else
		@assert length(log_λ) == length(λ) == size(lm.M, 1) == size(Δℓ_coeff, 1) == size(Δℓ_coeff, 2)
	end
	@assert size(A_sde) == size(Σ_sde)
	return Submodel{T, AV1, AV2}(log_λ, λ, lm, A_sde, Σ_sde, Δℓ_coeff)
end
(sm::Submodel)(inds::AbstractVecOrMat) =
	Submodel(sm.log_λ, sm.λ, LinearModel(sm.lm, inds), sm.A_sde, sm.Σ_sde, sm.Δℓ_coeff)
(sm::Submodel)() = sm.lm()
Base.copy(sm::Submodel) = Submodel(sm.log_λ, sm.λ, copy(sm.lm), sm.A_sde, sm.Σ_sde, sm.Δℓ_coeff)

function _shift_log_λ_model(log_λ_obs_from, log_λ_obs_to, log_λ_model_from)
	n_obs = size(log_λ_obs_from, 2)
	dop = [log_λ_obs_from[1, i] - log_λ_obs_to[1, i] for i in 1:n_obs]
	log_λ_model_to = ones(length(log_λ_model_from), n_obs)
	for i in 1:n_obs
		log_λ_model_to[:, i] .= log_λ_model_from .+ dop[i]
	end
	return log_λ_model_to
end

default_reg_tel = Dict([(:GP_μ, 1e1), (:L2_μ, 1e6), (:L1_μ, 1e2),
	(:L1_μ₊_factor, 6.), (:GP_M, 1e1), (:L2_M, 1e-1), (:L1_M, 1e3)])
default_reg_star = Dict([(:GP_μ, 1e1), (:L2_μ, 1e4), (:L1_μ, 1e3),
	(:L1_μ₊_factor, 7.2), (:GP_M, 1e1), (:L2_M, 1e1), (:L1_M, 1e6)])
# They need to be different or else the stellar μ will be surpressed
# default_reg_star = Dict([(:L2_μ, 1e6), (:L1_μ, 1e2),
# 	(:L1_μ₊_factor, 6.), (:L2_M, 1e-1), (:L1_M, 1e3)])

function oversamp_interp_helper(to_bounds::AbstractVector, from_x::AbstractVector)
	ans = spzeros(length(to_bounds)-1, length(from_x))
	bounds_inds = searchsortednearest(from_x, to_bounds)
	for i in 1:size(ans, 1)
		x_lo, x_hi = to_bounds[i], to_bounds[i+1]  # values of bounds
		lo_ind, hi_ind = bounds_inds[i], bounds_inds[i+1]  # indices of points in model closest to the bounds

		# if necessary, shrink so that so from_x[lo_ind] and from_x[hi_ind] are in the bounds
		if from_x[lo_ind] < x_lo; lo_ind += 1 end
		if from_x[hi_ind] > x_hi; hi_ind -= 1 end

		edge_term_lo = (from_x[lo_ind] - x_lo) ^ 2 / (from_x[lo_ind] - from_x[lo_ind-1])
		edge_term_hi = (x_hi - from_x[hi_ind]) ^ 2 / (from_x[hi_ind+1] - from_x[hi_ind])

		ans[i, lo_ind-1] = edge_term_lo
		ans[i, lo_ind] = from_x[lo_ind+1] + from_x[lo_ind] - 2 * x_lo - edge_term_lo

		ans[i, lo_ind+1:hi_ind-1] .= view(from_x, lo_ind+2:hi_ind) .- view(from_x, lo_ind:hi_ind-2)

		ans[i, hi_ind] = 2 * x_hi - from_x[hi_ind] - from_x[hi_ind-1] - edge_term_hi
		ans[i, hi_ind+1] = edge_term_hi
		# println(sum(view(ans, i, lo_ind-1:hi_ind+1))," vs ", 2 * (x_hi - x_lo))
		# @assert isapprox(sum(view(ans, i, lo_ind-1:hi_ind+1)), 2 * (x_hi - x_lo); rtol=1e-3)
		ans[i, lo_ind-1:hi_ind+1] ./= sum(view(ans, i, lo_ind-1:hi_ind+1))
		# ans[i, lo_ind-1:hi_ind+1] ./= 2 * (x_hi - x_lo)
	end
	dropzeros!(ans)
	return ans
end
oversamp_interp_helper(to_bounds::AbstractMatrix, from_x::AbstractVector) =
	[oversamp_interp_helper(view(to_bounds, :, i), from_x) for i in 1:size(to_bounds, 2)]

function undersamp_interp_helper(to_x::AbstractVector, from_x::AbstractVector)
	ans = spzeros(length(to_x), length(from_x))
	to_inds = searchsortednearest(from_x, to_x; lower=true)
	for i in 1:size(ans, 1)
		x_new = to_x[i]
		ind = to_inds[i]  # index of point in model below to_x[i]
		dif = (x_new-from_x[ind]) / (from_x[ind+1] - from_x[ind])
		ans[i, ind] = 1 - dif
		ans[i, ind + 1] = dif
	end
	dropzeros!(ans)
	return ans
end
undersamp_interp_helper(to_x::AbstractMatrix, from_x::AbstractVector) =
	[undersamp_interp_helper(view(to_x, :, i), from_x) for i in 1:size(to_x, 2)]

struct OrderModel{T<:Number}
    tel::Submodel
    star::Submodel
	rv::Submodel
	reg_tel::Dict{Symbol, T}
	reg_star::Dict{Symbol, T}
	b2o::AbstractVector{<:_current_matrix_modifier}
	t2o::AbstractVector{<:_current_matrix_modifier}
	metadata::Dict{Symbol, Any}
	n::Int
end
function OrderModel(
	d::Data,
	instrument::String,
	order::Int,
	star::String;
	n_comp_tel::Int=2,
	n_comp_star::Int=2,
	oversamp::Bool=true,
	kwargs...)

	tel = Submodel(d.log_λ_obs, n_comp_tel; type=:tel, kwargs...)
	star = Submodel(d.log_λ_star, n_comp_star; type=:star, kwargs...)
	rv = Submodel(d.log_λ_star, 1; include_mean=false, kwargs...)

	n_obs = size(d.log_λ_obs, 2)
	star_dop = [d.log_λ_star[1, i] - d.log_λ_obs[1, i] for i in 1:n_obs]
	star_log_λ_tel = ones(length(star.log_λ), n_obs)
	for i in 1:n_obs
		star_log_λ_tel[:, i] .= star.log_λ .+ star_dop[i]
	end
	todo = Dict([(:reg_improved, false), (:downsized, false), (:optimized, false), (:err_estimated, false)])
	metadata = Dict([(:todo, todo), (:instrument, instrument), (:order, order), (:star, star)])
	if oversamp
		b2o = oversamp_interp_helper(d.log_λ_star_bounds, star.log_λ)
		t2o = oversamp_interp_helper(d.log_λ_obs_bounds, tel.log_λ)
	else
		b2o = undersamp_interp_helper(d.log_λ_star, star.log_λ)
		t2o = undersamp_interp_helper(d.log_λ_obs, tel.log_λ)
	end
	return OrderModel(tel, star, rv, copy(default_reg_tel), copy(default_reg_star), b2o, t2o, metadata, n_obs)
end
Base.copy(om::OrderModel) = OrderModel(copy(om.tel), copy(om.star), copy(om.rv), copy(om.reg_tel), copy(om.reg_star), om.b2o, om.t2o, copy(om.metadata), om.n)
(om::OrderModel)(inds::AbstractVecOrMat) =
	OrderModel(om.tel(inds), om.star(inds), om.rv(inds), om.reg_tel,
		om.reg_star, view(om.b2o, inds), view(om.t2o, inds), copy(om.metadata), length(inds))
function rm_regularization(om::OrderModel)
	for (key, value) in om.reg_tel
		delete!(om.reg_tel, key)
		# om.reg_tel[key] = 0
	end
	for (key, value) in om.reg_star
		delete!(om.reg_star, key)
		# om.reg_star[key] = 0
	end
end

function _eval_lm_vec(om::OrderModel, v)
	@assert 0 < length(v) < 4
	if length(v)==1
		return _eval_lm(v[1], om.n)
	elseif length(v)==2
		return _eval_lm(v[1], v[2])
	elseif length(v)==3
		return _eval_lm(v[1], v[2], v[3])
	end
end

# I have no idea why the negative sign needs to be here
rvs(model::OrderModel) = vec(model.rv.lm.s .* -light_speed_nu)

function downsize(lm::FullLinearModel, n_comp::Int)
	if n_comp > 0
		return FullLinearModel(lm.M[:, 1:n_comp], lm.s[1:n_comp, :], lm.μ[:])
	else
		return TemplateModel(lm.μ[:], size(lm.s, 2))
	end
end
downsize(lm::BaseLinearModel, n_comp::Int) =
	BaseLinearModel(lm.M[:, 1:n_comp], lm.s[1:n_comp, :])
downsize(sm::Submodel, n_comp::Int) =
	Submodel(copy(sm.log_λ), copy(sm.λ), downsize(sm.lm, n_comp), copy(sm.A_sde), copy(sm.Σ_sde), copy(sm.Δℓ_coeff))
downsize(m::OrderModel, n_comp_tel::Int, n_comp_star::Int) =
	OrderModel(
		downsize(m.tel, n_comp_tel),
		downsize(m.star, n_comp_star),
		m.rv, m.reg_tel, m.reg_star, m.b2o, m.t2o, m.metadata, m.n)

spectra_interp(model::AbstractMatrix, interp_helper::AbstractVector{<:_current_matrix_modifier}) =
	hcat([interp_helper[i] * view(model, :, i) for i in 1:size(model, 2)]...)
spectra_interp_nabla(model, interp_helper::AbstractVector{<:_current_matrix_modifier}) =
	hcat([interp_helper[i] * model[:, i] for i in 1:size(model, 2)]...)
spectra_interp(model, interp_helper::AbstractVector{<:_current_matrix_modifier}) =
	spectra_interp_nabla(model, interp_helper)

@explicit_intercepts spectra_interp Tuple{AbstractMatrix, AbstractVector{<:_current_matrix_modifier}}
Nabla.∇(::typeof(spectra_interp), ::Type{Arg{1}}, _, y, ȳ, model, interp_helper) =
	hcat([interp_helper[i]' * view(ȳ, :, i) for i in 1:size(model, 2)]...)

tel_model(om::OrderModel; lm=om.tel.lm::LinearModel) = spectra_interp(lm(), om.t2o)
star_model(om::OrderModel; lm=om.star.lm::LinearModel) = spectra_interp(lm(), om.b2o)
rv_model(om::OrderModel; lm=om.rv.lm::LinearModel) = spectra_interp(lm(), om.b2o)


function fix_FullLinearModel_s!(flm, min::Number, max::Number)
	@assert all(min .< flm.μ .< max)
	result = ones(typeof(flm.μ[1]), length(flm.μ))
	for i in 1:size(flm.s, 2)
		result[:] = _eval_lm(flm.M, flm.s[:, i], flm.μ)
		while any(result .> max) || any(result .< min)
			# println("$i, old s: $(lm.s[:, i]), min: $(minimum(result)), max:  $(maximum(result))")
			flm.s[:, i] ./= 2
			result[:] = _eval_lm(flm.M, view(flm.s, :, i), flm.μ)
			# println("$i, new s: $(lm.s[:, i]), min: $(minimum(result)), max:  $(maximum(result))")
		end
	end
end

function get_marginal_GP(
    finite_GP::Distribution{Multivariate,Continuous},
    ys::AbstractVector,
    xs::AbstractVector)
    gp_post = posterior(finite_GP, ys)
    gpx_post = gp_post(xs)
    return TemporalGPs.marginals(gpx_post)
end

function get_mean_GP(
    finite_GP::Distribution{Multivariate,Continuous},
    ys::AbstractVector,
    xs::AbstractVector)
    return mean.(get_marginal_GP(finite_GP, ys, xs))
end

function build_gp(params::NamedTuple)
	f_naive = AbstractGPs.GP(params.var_kernel * Matern52Kernel() ∘ ScaleTransform(params.λ))
	return to_sde(f_naive, SArrayStorage(Float64))
end

SOAP_gp_params = (var_kernel = 0.2188511770097717, λ = 26063.07237159581)
SOAP_gp = build_gp(SOAP_gp_params)
LSF_gp_params = (var_kernel = 0.20771264919723142, λ = 114294.15657857814)
LSF_gp = build_gp(LSF_gp_params)

# ParameterHandling version
# SOAP_gp_params = (var_kernel = positive(3.3270754364467443), λ = positive(1 / 9.021560480866474e-5))
# flat_SOAP_gp_params, unflatten = value_flatten(SOAP_gp_params)
# # unflatten(flat_SOAP_gp_params) == ParameterHandling.value(SOAP_gp_params)  # true
# SOAP_gp = build_gp(ParameterHandling.value(SOAP_gp_params))

function _spectra_interp_gp!(fluxes, vars, log_λ, flux_obs, var_obs, log_λ_obs; gp_mean::Number=1.)
	for i in 1:size(flux_obs, 2)
		gp = get_marginal_GP(SOAP_gp(view(log_λ_obs, :, i), view(var_obs, :, i)), view(flux_obs, :, i) .- gp_mean, log_λ)
		fluxes[:, i] .= mean.(gp) .+ gp_mean
        vars[:, i] .= var.(gp)
	end
end

function _spectra_interp_gp_div_gp!(fluxes::AbstractMatrix, vars::AbstractMatrix, log_λ::AbstractVector, flux_obs::AbstractMatrix, var_obs::AbstractMatrix, log_λ_obs::AbstractMatrix, flux_other::AbstractMatrix, var_other::AbstractMatrix, log_λ_other::AbstractMatrix; gp_mean::Number=1.)
	for i in 1:size(flux_obs, 2)
		gpn = get_marginal_GP(SOAP_gp(view(log_λ_obs, :, i), view(var_obs, :, i)), view(flux_obs, :, i) .- gp_mean, log_λ)
		gpd = get_marginal_GP(SOAP_gp(view(log_λ_other, :, i), view(var_other, :, i)), view(flux_other, :, i) .- gp_mean, log_λ)
		gpn_μ = mean.(gpn) .+ gp_mean
		gpd_μ = mean.(gpd) .+ gp_mean
		fluxes[:, i] .= gpn_μ ./ gpd_μ
        vars[:, i] .= (var.(gpn) .+ ((gpn_μ .^ 2 .* var.(gpd)) ./ (gpd_μ .^2))) ./ (gpd_μ .^2)
	end
end

# function n_comps_needed(sm::Submodel; threshold::Real=0.05)
#     @assert 0 < threshold < 1
#     s_var = sum(abs2, sm.lm.s; dims=2)
#     return findfirst(s_var ./ sum(s_var) .< threshold)[1] - 1
# end

function initialize!(om::OrderModel, d::Data; min::Number=0, max::Number=1.2, kwargs...)

	μ_min = min + 0.05
	μ_max = max - 0.05

	n_obs = size(d.flux, 2)
	n_comp_star = size(om.star.lm.M, 2) + 1
	n_comp_tel = size(om.tel.lm.M, 2)

	star_log_λ_tel = _shift_log_λ_model(d.log_λ_obs, d.log_λ_star, om.star.log_λ)
	tel_log_λ_star = _shift_log_λ_model(d.log_λ_star, d.log_λ_obs, om.tel.log_λ)
	flux_star = ones(length(om.star.log_λ), n_obs)
	vars_star = ones(length(om.star.log_λ), n_obs)
	flux_tel = ones(length(om.tel.log_λ), n_obs)
	vars_tel = ones(length(om.tel.log_λ), n_obs)
	_spectra_interp_gp!(flux_star, vars_star, om.star.log_λ, d.flux, d.var, d.log_λ_star)

	om.star.lm.μ[:] = make_template(flux_star; min=μ_min, max=μ_max)
	_, _, _, rvs_naive =
	    DPCA(flux_star, om.star.λ; template=om.star.lm.μ, num_components=1)

	# telluric model with stellar template
	flux_star .= om.star.lm.μ
	_spectra_interp_gp_div_gp!(flux_tel, vars_tel, om.tel.log_λ, d.flux, d.var, d.log_λ_obs, flux_star, vars_star, star_log_λ_tel)

	om.tel.lm.μ[:] = make_template(flux_tel; min=μ_min, max=μ_max)
	# _, om.tel.lm.M[:, :], om.tel.lm.s[:, :], _ =
	#     fit_gen_pca(flux_tel; num_components=n_comp_tel, mu=om.tel.lm.μ)

	# stellar model with telluric template
	flux_tel .= om.tel.lm.μ
	_spectra_interp_gp_div_gp!(flux_star, vars_star, om.star.log_λ, d.flux, d.var, d.log_λ_star, flux_tel, vars_tel, tel_log_λ_star)

	om.star.lm.μ[:] = make_template(flux_star; min=μ_min, max=μ_max)
	# _, M_star, s_star, rvs_notel =
	#     DEMPCA(flux_star, om.star.λ, 1 ./ vars_star; template=om.star.lm.μ, num_components=n_comp_star, kwargs...)
	_, M_star, s_star, rvs_notel =
		DEMPCA(flux_star, om.star.λ, 1 ./ vars_star; template=om.star.lm.μ, num_components=n_comp_star)
	fracvar_star = fracvar(flux_star .- om.star.lm.μ, M_star, s_star, 1 ./ vars_star)

	# telluric model with updated stellar template
	flux_star .= om.star.lm.μ
	_spectra_interp_gp_div_gp!(flux_tel, vars_tel, om.tel.log_λ, d.flux, d.var, d.log_λ_obs, flux_star, vars_star, star_log_λ_tel)

	om.tel.lm.μ[:] = make_template(flux_tel; min=μ_min, max=μ_max)
	Xtmp = flux_tel .- om.tel.lm.μ
	# EMPCA!(om.tel.lm.M, Xtmp, om.tel.lm.s, 1 ./ vars_tel; kwargs...)
	EMPCA!(om.tel.lm.M, Xtmp, om.tel.lm.s, 1 ./ vars_tel)
	fracvar_tel = fracvar(Xtmp, om.tel.lm.M, om.tel.lm.s, 1 ./ vars_tel)

	om.star.lm.M .= view(M_star, :, 2:size(M_star, 2))
	om.star.lm.s[:] = view(s_star, 2:size(s_star, 1), :)
	om.rv.lm.M .= view(M_star, :, 1)
	om.rv.lm.s[:] = view(s_star, 1, :)

	fix_FullLinearModel_s!(om.star.lm, min, max)
	fix_FullLinearModel_s!(om.tel.lm, min, max)

	return rvs_notel, rvs_naive, fracvar_tel, fracvar_star
end

L1(a) = sum(abs, a)
L2(a) = sum(abs2, a)
L∞(Δ::VecOrMat{<:Real}) = maximum(Δ)
L∞(Δ) = maximum(L∞.(Δ))
function shared_attention(M)
	shared_attentions = M' * M
	return sum(shared_attentions) - sum(diag(shared_attentions))
end


function model_prior(lm, om::OrderModel, key::Symbol)
	reg = getfield(om, Symbol(:reg_, key))
	sm = getfield(om, key)
	isFullLinearModel = length(lm) > 2
	val = 0

	if haskey(reg, :L2_μ) || haskey(reg, :L1_μ) || haskey(reg, :L1_μ₊_factor)
		μ_mod = lm[1+2*isFullLinearModel] .- 1
		if haskey(reg, :L2_μ); val += L2(μ_mod) * reg[:L2_μ] end
		if haskey(reg, :L1_μ)
			val += L1(μ_mod) * reg[:L1_μ]
			# For some reason dot() works but BLAS.dot() doesn't
			if haskey(reg, :L1_μ₊_factor); val += dot(μ_mod, μ_mod .> 0) * reg[:L1_μ₊_factor] * reg[:L1_μ] end
		end
		# if haskey(reg, :GP_μ); val -= logpdf(SOAP_gp(getfield(om, key).log_λ), μ_mod) * reg[:GP_μ] end
		# if haskey(reg, :GP_μ); val -= gp_ℓ_nabla(μ_mod, sm.A_sde, sm.Σ_sde) * reg[:GP_μ] end
		if haskey(reg, :GP_μ); val -= gp_ℓ_precalc(sm.Δℓ_coeff, μ_mod, sm.A_sde, sm.Σ_sde) * reg[:GP_μ] end
	end
	if isFullLinearModel
		if haskey(reg, :shared_M); val += shared_attention(lm[1]) * reg[:shared_M] end
		if haskey(reg, :L2_M); val += L2(lm[1]) * reg[:L2_M] end
		if haskey(reg, :L1_M); val += L1(lm[1]) * reg[:L1_M] end
		if haskey(reg, :GP_M)
			for i in 1:size(lm[1], 2)
				val -= gp_ℓ_precalc(sm.Δℓ_coeff,lm[1][:, i], sm.A_sde, sm.Σ_sde) * reg[:GP_μ]
			end
		end
		if (haskey(reg, :L1_M) && reg[:L1_M] != 0) || (haskey(reg, :L2_M) && reg[:L2_M] != 0) || (haskey(reg, :GP_M) && reg[:GP_M] != 0); val += L1(lm[2]) end
	end
	return val
end
model_prior(lm::Union{FullLinearModel, TemplateModel}, om::OrderModel, key::Symbol) = model_prior(vec(lm), om, key)

tel_prior(om::OrderModel) = tel_prior(om.tel.lm, om)
tel_prior(lm, om::OrderModel) = model_prior(lm, om, :tel)
star_prior(om::OrderModel) = star_prior(om.star.lm, om)
star_prior(lm, om::OrderModel) = model_prior(lm, om, :star)

total_model(tel, star, rv) = tel .* (star .+ rv)

struct Output{T<:Number, AM<:AbstractMatrix{T}, M<:Matrix{T}}
	tel::AM
	star::AM
	rv::AM
	total::M
	function Output(tel::AM, star::AM, rv::AM, total::M) where {T<:Number, AM<:AbstractMatrix{T}, M<:Matrix{T}}
		@assert size(tel) == size(star) == size(rv) == size(total)
		new{T, AM, M}(tel, star, rv, total)
	end
end
function Output(om::OrderModel, d::Data)
	@assert size(om.b2o[1], 1) == size(d.flux, 1)
	return Output(tel_model(om), star_model(om), rv_model(om), d)
end
Output(tel, star, rv, d::GenericData) =
	Output(tel, star, rv, total_model(tel, star, rv))
Output(tel, star, rv, d::LSFData) =
	Output(tel, star, rv, d.lsf * total_model(tel, star, rv))
Base.copy(o::Output) = Output(copy(tel), copy(star), copy(rv))
function recalc_total!(o::Output, d::GenericData)
	o.total .= total_model(o.tel, o.star, o.rv)
end
function recalc_total!(o::Output, d::LSFData)
	o.total .= d.lsf * total_model(o.tel, o.star, o.rv)
end
function Output!(o::Output, om::OrderModel, d::Data)
	o.tel .= tel_model(om)
	o.star .= star_model(om)
	o.rv .= rv_model(om)
	recalc_total!(o, d)
end

function copy_reg!(from::OrderModel, to::OrderModel)
	copy_dict!(to.reg_tel, from.reg_tel)
	copy_dict!(to.reg_star, from.reg_star)
end
