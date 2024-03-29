### A Pluto.jl notebook ###
# v0.19.16

using Markdown
using InteractiveUtils

# ╔═╡ cc48914c-6e47-11ec-2ebb-a734d4f5f9fc
begin
	using CairoMakie
	using Clp
	using Colors
	using Distributions
	using JuMP
	using LinearAlgebra
	using PlutoUI
	using ProgressLogging
	using Random
	using Statistics
end

# ╔═╡ 8844d3f8-8317-4e7b-98fe-da3403be173c
PlutoUI.TableOfContents()

# ╔═╡ 8acaf22f-1d73-4d20-a489-7e2851fb7a08
plot_path = "plots/"

# ╔═╡ 8e89c07e-c324-46ca-bdee-14ee9d366220
md"""
# Context
"""

# ╔═╡ 1a3ebfe0-2bae-4e7c-8bfc-0ec9717f303b
md"""
This notebook contains code for the paper [Minimax Estimation of Partially-Observed Vector AutoRegressions](https://hal.archives-ouvertes.fr/hal-03263275). It focuses on the model defined by
```math
X_t = \theta X_{t-1} + \mathcal{N}(0, \sigma^2 I)
\qquad \qquad
Y_t = \Pi_t X_t + \mathcal{N}(0, \omega^2 I)
```
where the sampling process satisfies
```math
(\pi_{t, d})_t \sim \mathrm{Markov} \begin{pmatrix} 1-a & a \\ b & 1-b \end{pmatrix} \qquad \qquad \Pi_t = \mathrm{diag}(\pi_t)
```
with $p = \frac{a}{a+b}$.

The estimator we use is constructed as follows:
```math
\widehat{\theta} \in \mathrm{argmin}_{M \in \mathbb{R}^{D \times D}} \lVert \mathrm{vec}(M) \rVert_1 \quad \text{s.t.} \quad \lVert M \widehat{\Gamma}_{h_0} - \widehat{\Gamma}_{h_0+1} \rVert_{\max} \leq \lambda
```
where the rank-$h$ covariance estimators are given by
```math
\widehat{\Gamma}_h :=  \frac{1}{S(h)} \odot \frac{1}{T-h} \sum_{t=1}^{T-h} \left(\Pi_{t+h}' Y_{t+h}\right) \left(\Pi_t' Y_{t}\right)' - \mathbf{1}_{h=0} \omega^2 I.
```
"""

# ╔═╡ 01676dff-d535-4acd-9d28-85221e1d34f7
md"""
# Core code
"""

# ╔═╡ 2fcdb163-f32c-4dd5-87ff-d463fd521ce4
md"""
## Simulation
"""

# ╔═╡ b641ffb3-d1ad-40e2-be79-bac2dddde8cf
begin
	D̄ = 5
	σ̄ = 1.
	p̄ = 1.
	ω̄ = 0.1
	T̄ = 10_000
end;

# ╔═╡ 934fa46d-3b64-48fe-a325-72bf1a453dcc
function simulate_povar(θ, σ, a, b, ω, T)
	D = size(θ, 1)
	X = Matrix{Float64}(undef, T, D)
	π = Matrix{Bool}(undef, T, D)
	Y = Matrix{Float64}(undef, T, D)

	# State process
	Σ₀ = σ^2 * inv(I - Symmetric(θ * θ'))
	X[1, :] .= rand(MvNormal(zeros(D), Σ₀))
	for t = 2:T
		X[t, :] .= θ * X[t-1, :] + σ * randn(D)
	end

	# Sampling
	p = a / (a + b)
	π[1, :] = rand(Bernoulli(p), D)
	for t = 2:T, d = 1:D
		if π[t-1, d]
			π[t, d] = rand(Bernoulli(1 - b))
		else
			π[t, d] = rand(Bernoulli(a))
		end
	end

	# Observations
	for t = 1:T
		Y[t, :] = π[t, :] .* (X[t, :] + ω * randn(D))
	end

	return X, π, Y
end

# ╔═╡ c3f1ddbf-2670-4705-ae5d-6bb419e9fef2
md"""
## Estimation
"""

# ╔═╡ 084dcbd4-f677-44c7-9fc1-03bf43efab79
function scaling_matrix(D, a, b, h)
	p = a / (a + b)
	S = Matrix{Float64}(undef, D, D)
	for d₁ = 1:D, d₂ = 1:D
		if d₁ != d₂
			S[d₁, d₂] = p^2
		elseif h == 0
			S[d₁, d₂] = p
		else
			S[d₁, d₂] = p^2 + p*(1-p)*(1-a-b)^h
		end
	end
	return S
end

# ╔═╡ 40937800-850a-4ebe-8b13-a84c1e38a973
function estimate_Γ(π, Y, a, b, ω, h)
	T, D = size(Y)
	Γₕ = zeros(D, D)
	X̂ = π .* Y
	for t = 1:(T-h)
		Γₕ += (X̂[t+h, :] * X̂[t, :]') / (T-h)
	end
	Γₕ ./= scaling_matrix(D, a, b, h)
	Γₕ -= (h == 0) * ω^2 * I
	return Γₕ
end

# ╔═╡ d20e47e7-b002-4d1a-89bd-2221032c7190
function estimate_θ_dense(π, Y, a, b, ω, h₀)
	Γ₀ = estimate_Γ(π, Y, a, b, ω, h₀)
	Γ₁ = estimate_Γ(π, Y, a, b, ω, h₀+1)
	return Γ₁ * pinv(Γ₀)
end

# ╔═╡ bf02237e-8a46-4bbf-8f3e-01b518680c57
function estimate_θ_sparse(π, Y, a, b, ω, h₀, ŝ)
	T, D = size(Y)
	Γ₀ = estimate_Γ(π, Y, a, b, ω, h₀)
	Γ₁ = estimate_Γ(π, Y, a, b, ω, h₀+1)

	model = Model(Clp.Optimizer)
	set_optimizer_attribute(model, "LogLevel", 0)
	@variable(model, θ₊[1:D, 1:D] >= 0)
	@variable(model, θ₋[1:D, 1:D] >= 0)
	@variable(model, λ)
	@constraint(model, (θ₊ - θ₋) * Γ₀ - Γ₁ .<= λ)
	@constraint(model, Γ₁ - (θ₊ - θ₋) * Γ₀ .<= λ)
	@objective(model, Min, sum(θ₊ + θ₋))

	# Choose the best λ to achieve sparsity ŝ
	λₘᵢₙ, λₘₐₓ = 0, 1e2
	while true
		fix(λ, (λₘₐₓ + λₘᵢₙ) / 2)
		optimize!(model)
		@assert termination_status(model) == MOI.OPTIMAL
		θ̂ = value.(θ₊) .- value.(θ₋)
		if (λₘₐₓ - λₘᵢₙ) / λₘₐₓ < 0.1  # convergence achieved
			return θ̂
		else  # bisect based on sparsity
			s = sum(.!(θ̂ .≈ 0.)) / D
			if  s < ŝ  # too sparse
				λₘₐₓ = (λₘₐₓ + λₘᵢₙ) / 2
			else  # not sparse enough
				λₘᵢₙ = (λₘₐₓ + λₘᵢₙ) / 2
			end
		end
	end
	return θ̂
end

# ╔═╡ 7c66f7a5-e8b1-40af-aa42-9b88bd17abb7
function random_θ(D, s)
	θ = zeros(D, D)
	for d₁ = 1:D
		nonzero_columns = sample(1:D, s, replace=false)
		for d₂ in nonzero_columns
			θ[d₁, d₂] = randn()
		end
	end
	return 0.5 * θ / opnorm(θ, 2)
end

# ╔═╡ dffa0866-6d21-4665-8013-92bbeaab7b69
function estimation_error(;
	D=D̄,
	s=D,
	σ=σ̄,
	p=p̄,
	a=nothing,
	b=nothing,
	ω=ω̄,
	T=T̄,
	h₀=0,
	ŝ=D
)
	θ = random_θ(D, s)
	if isnothing(a) && isnothing(b)
		a, b = p, 1 - p
	end
	X, π, Y = simulate_povar(θ, σ, a, b, ω, T)
	if ŝ == D
		θ̂ = estimate_θ_dense(π, Y, a, b, ω, h₀)
	else
		θ̂ = estimate_θ_sparse(π, Y, a, b, ω, h₀, ŝ)
	end
	return opnorm(θ̂ - θ, Inf)
end

# ╔═╡ f3744ba6-4f83-4a8b-acae-e539b043023d
md"""
# Plots
"""

# ╔═╡ d6b5a773-40bc-4c7f-a2d5-5f83a7c5faed
p_values = [0.1, 0.2, 0.5, 1.]

# ╔═╡ c28202b4-09c7-4c91-81e8-58bbad6ea08f
p_colors = Colors.JULIA_LOGO_COLORS

# ╔═╡ 65a20d43-3eb4-4dc5-a7e3-35a997ba34f6
p_markers = [:circle, :pentagon, :rect, :utriangle]

# ╔═╡ 026629b2-7fae-441e-a2cc-c6e21f000d90
npoints = 100

# ╔═╡ faf615b2-d17b-48e3-891b-46db7bd4245b
function theil_sen(x, y)
	n = length(x)
	slopes = [(y[j] - y[i]) / (x[j] - x[i]) for i = 1:n for j = (i+1):n]
	α = median(slopes)
	intercepts = [y[i] - α * x[i] for i = 1:n]
	β = median(intercepts)
	return α, β
end

# ╔═╡ cb0cd770-9aec-463f-ba2f-a04c712a2e62
md"""
## Influence of $T$
"""

# ╔═╡ bbb959dd-74c8-4924-9eee-52ea4c67cc3e
T_values = round.(Int, 10 .^ range(2, 5, npoints))

# ╔═╡ 9288b659-c784-48ea-9110-5cf33f68179b
begin
	Random.seed!(63)
	T_errors = Dict(p => Float64[] for p in p_values)
	@progress for p in p_values, T in T_values
		push!(T_errors[p], estimation_error(p=p, T=T))
	end
end

# ╔═╡ be6db533-e3d4-4d96-bc90-8063db960a7f
begin
	fig_T = Figure()
	ax_T = Axis(
		fig_T[1, 1],
		xlabel=L"Period length $T$",
		ylabel=L"Estimation error $||\hat{\theta} - \theta ||_{\infty}$",
		xscale=log10,
		yscale=log10,
	)
	for (k, p) in enumerate(p_values)
		α, β = round.(
			theil_sen(log10.(T_values), log10.(T_errors[p])),
			digits=2
		)
		lines!(
			ax_T,
			T_values,
			10 .^ (α * log10.(T_values) .+ β),
			color=p_colors[k],
		)
		scatter!(
			ax_T,
			T_values,
			T_errors[p],
			marker=p_markers[k],
			color=p_colors[k],
			strokewidth=2,
			strokecolor=p_colors[k],
			label=L"p=%$p ~|~ \alpha=%$α"
		)
	end
	axislegend(ax_T)
	save(joinpath(plot_path, "influence_T.pdf"), fig_T)
	fig_T
end

# ╔═╡ f35c9fd1-be04-47f9-a390-4ed891c9e616
md"""
## Influence of $D$
"""

# ╔═╡ 758f7227-e647-4378-bae7-98267f977ba3
D_values = round.(Int, 10 .^ range(0.5, 2, npoints))

# ╔═╡ 66fb58c0-c7ef-4e14-b73a-c869d9962cc1
begin
	Random.seed!(63)
	D_errors = Dict(p => Float64[] for p in p_values)
	@progress for p in p_values, D in D_values
		push!(D_errors[p], estimation_error(p=p, D=D))
	end
end

# ╔═╡ 99801229-d58b-41a1-aae7-fd672f9b0f97
begin
	fig_D = Figure()
	ax_D = Axis(
		fig_D[1, 1],
		xlabel=L"State dimension $D$",
		ylabel=L"Estimation error $||\hat{\theta} - \theta ||_{\infty}$",
		xscale=log10,
		yscale=log10,
	)
	for (k, p) in enumerate(p_values)
		α, β = round.(
			theil_sen(log10.(D_values), log10.(D_errors[p])),
			digits=2
		)
		lines!(
			ax_D,
			D_values,
			10 .^ (α * log10.(D_values) .+ β),
			color=p_colors[k]
		)
		scatter!(
			ax_D,
			D_values,
			D_errors[p],
			marker=p_markers[k],
			color=p_colors[k],
			strokewidth=2,
			strokecolor=p_colors[k],
			label=L"p=%$p ~|~ \alpha=%$α"
		)
	end
	axislegend(ax_D, position=:lt)
	save(joinpath(plot_path, "influence_D.pdf"), fig_D)
	fig_D
end

# ╔═╡ 56c6cd18-fbc3-47e5-945c-53fd6293c6b6
md"""
## Influence of $\omega$
"""

# ╔═╡ 602588a7-1989-4dd3-a66a-e5f6bf72f904
ω_values = 10 .^ range(-2, 2, npoints)

# ╔═╡ a214165b-2903-42a0-88f1-ecd0f3a90e82
begin
	Random.seed!(63)
	ω_errors = Dict(p => Float64[] for p in p_values)
	@progress for p in p_values, ω in ω_values
		push!(ω_errors[p], estimation_error(p=p, ω=ω))
	end
end

# ╔═╡ 8b554763-8a84-4497-b5c1-2f5e3a41b96e
begin
	fig_ω = Figure()
	ax_ω = Axis(
		fig_ω[1, 1],
		xlabel=L"Variance ratio $\omega^2 / \sigma^2$",
		ylabel=L"Estimation error $||\hat{\theta} - \theta ||_{\infty}$",
		xscale=log10,
		yscale=log10,
	)
	for (k, p) in enumerate(p_values)
		scatter!(
			ax_ω,
			ω_values .^2,
			ω_errors[p],
			marker=p_markers[k],
			color=p_colors[k],
			strokewidth=2,
			strokecolor=p_colors[k],
			label=L"p=%$p"
		)
	end
	axislegend(ax_ω, position=:lt)
	save(joinpath(plot_path, "influence_omega.pdf"), fig_ω)
	fig_ω
end

# ╔═╡ 5d398ec9-13db-4a29-bf20-8551e757d92c
md"""
## Influence of $s$ (fixed $D$)
"""

# ╔═╡ db0e8104-918c-46a0-9f50-920b44474dcd
D_for_s = 50

# ╔═╡ 7c0fbd79-e9c2-49b3-98c4-f67bb730d49e
s_values = 5:1:30

# ╔═╡ dd47d8a8-b379-4cc5-991d-6df0d0f6fcb7
begin
	Random.seed!(63)
	s_errors_dense = Dict(p => Float64[] for p in p_values)
	s_errors_sparse = Dict(p => Float64[] for p in p_values)
	@progress for p in p_values, s in s_values
		push!(
			s_errors_dense[p],
			estimation_error(p=p, D=D_for_s, s=s, ŝ=D_for_s)
		)
		push!(
			s_errors_sparse[p],
			estimation_error(p=p, D=D_for_s, s=s, ŝ=s)
		)
	end
end

# ╔═╡ 16ae6f4e-d74d-4263-9ca8-b2b14ec71d3a
begin
	fig_s = Figure()
	ax_s = Axis(
		fig_s[1, 1],
		xlabel=L"Transition sparsity $s$ (with $D = %$D_for_s$)",
		ylabel=L"Estimation error $||\hat{\theta} - \theta ||_{\infty}$",
		xscale=log10,
		yscale=log10,
	)
	for (k, p) in enumerate(p_values)
		# p == 0.1 && continue
		α, β = round.(
			theil_sen(log10.(s_values), log10.(s_errors_sparse[p])),
			digits=2
		)
		lines!(
			ax_s,
			s_values,
			10 .^ (α * log10.(s_values) .+ β),
			color=p_colors[k],
			linestyle=:dot
		)
		scatter!(
			ax_s,
			s_values,
			s_errors_sparse[p],
			marker=p_markers[k],
			color=:white,
			strokewidth=2,
			strokecolor=p_colors[k],
			label=L"$p=%$p$ (sparse)$~|~ \alpha=%$α$"
		)
	end
	axislegend(ax_s, position=:lt)
	save(joinpath(plot_path, "influence_s_fixed_D.pdf"), fig_s)
	fig_s
end

# ╔═╡ 5781a0d3-428d-410f-8acb-5cd1a39118a1
md"""
## Influence of $D$ (fixed $s$)
"""

# ╔═╡ aef4d77b-ee37-4f27-b350-7939520f0e48
s_for_D = 5

# ╔═╡ 29d1d386-52ca-4ff5-93a7-d4eeda1d758f
D_values_for_s = 5:1:50

# ╔═╡ cf97f7df-3930-4fc8-8077-6379a7365e5c
begin
	Random.seed!(63)
	Ds_errors_dense = Dict(p => Float64[] for p in p_values)
	Ds_errors_sparse = Dict(p => Float64[] for p in p_values)
	@progress for p in [0.2, 1.], D in D_values_for_s
		push!(
			Ds_errors_dense[p],
			estimation_error(p=p, D=D, s=s_for_D, ŝ=D)
		)
		push!(
			Ds_errors_sparse[p],
			estimation_error(p=p, D=D, s=s_for_D, ŝ=s_for_D)
		)
	end
end

# ╔═╡ a1c9b17b-a5b5-43a0-824d-64b7de26be76
begin
	fig_Ds = Figure()
	ax_Ds = Axis(
		fig_Ds[1, 1],
		xlabel=L"State dimension $D$ (with $s = %$s_for_D$)",
		ylabel=L"Estimation error $||\hat{\theta} - \theta ||_{\infty}$",
		xscale=log10,
		yscale=log10,
	)
	for (k, p) in enumerate(p_values)
		p in [0.1, 0.5] && continue
		α_dense, β_dense = round.(
			theil_sen(log10.(D_values_for_s), log10.(Ds_errors_dense[p])),
			digits=2
		)
		lines!(
			ax_Ds,
			D_values_for_s,
			10 .^ (α_dense * log10.(D_values_for_s) .+ β_dense),
			color=p_colors[k],
		)
		scatter!(
			ax_Ds,
			D_values_for_s,
			Ds_errors_dense[p],
			marker=p_markers[k],
			color=p_colors[k],
			strokewidth=2,
			strokecolor=p_colors[k],
			label=L"$p=%$p$ (dense) $|~ \alpha=%$α_dense$"
		)
	end
	for (k, p) in enumerate(p_values)
		p in [0.1, 0.5] && continue
		α_sparse, β_sparse = round.(
			theil_sen(log10.(D_values_for_s), log10.(Ds_errors_sparse[p])),
			digits=2
		)
		lines!(
			ax_Ds,
			D_values_for_s,
			10 .^ (α_sparse * log10.(D_values_for_s) .+ β_sparse),
			color=p_colors[k],
			linestyle=:dot
		)
		scatter!(
			ax_Ds,
			D_values_for_s,
			Ds_errors_sparse[p],
			marker=p_markers[k],
			color=:white,
			strokewidth=2,
			strokecolor=p_colors[k],
			label=L"$p=%$p$ (sparse) $|~ \alpha=%$α_sparse$"
		)
	end
	axislegend(ax_Ds, position=:lt, nbanks=1)
	save(joinpath(plot_path, "influence_D_fixed_s.pdf"), fig_Ds)
	fig_Ds
end

# ╔═╡ 3e99926b-bcba-4446-9485-c14e02aaf880
md"""
## Influence of $h_0$
"""

# ╔═╡ 4f3ff83f-56b9-42b7-9844-cebf8eea9323
h₀_values = [1, 0]

# ╔═╡ 0ecd2072-8669-48c3-90c4-eea124a7b164
h₀_colors = [:royalblue1, :midnightblue]

# ╔═╡ eb014af1-18e4-4eda-8a65-7c8d630c3054
h₀_markers = [:xcross, :cross]

# ╔═╡ f033f1d8-24c6-4d82-8ada-599916dc5ff6
p_values_for_h₀ = 10 .^ range(-1, 0, npoints)

# ╔═╡ dc8c82bd-7074-46e4-b574-1f6a3b810cd9
begin
	Random.seed!(63)
	h₀_errors = Dict(h₀ => Float64[] for h₀ in h₀_values)
	@progress for h₀ in h₀_values, p in p_values_for_h₀
		push!(h₀_errors[h₀], estimation_error(p=p, h₀=h₀))
	end
end

# ╔═╡ 5595ed61-e5f1-4686-b8f6-9c3587270ea5
begin
	fig_h₀ = Figure()
	ax_h₀ = Axis(
		fig_h₀[1, 1],
		xlabel=L"Sampling probability $p$",
		ylabel=L"Estimation error $||\hat{\theta} - \theta ||_{\infty}$",
		xscale=log10,
		yscale=log10,
	)
	for (k, h₀) in enumerate(h₀_values)
		α, β = round.(
			theil_sen(log10.(p_values_for_h₀), log10.(h₀_errors[h₀])),
			digits=2
		)
		scatter!(
			ax_h₀,
			p_values_for_h₀,
			h₀_errors[h₀],
			marker=h₀_markers[k],
			color=h₀_colors[k],
			label=L"h₀=%$h₀ ~|~ \alpha=%$α"
		)
		lines!(
			ax_h₀,
			p_values_for_h₀,
			10 .^ (α * log10.(p_values_for_h₀) .+ β),
			color=h₀_colors[k],
		)
	end
	axislegend(ax_h₀)
	save(joinpath(plot_path, "influence_h0.pdf"), fig_h₀)
	fig_h₀
end

# ╔═╡ 2c7f8e1b-66af-4d40-8aef-7a2c6ea3ad03
md"""
## Influence of $b$
"""

# ╔═╡ 3a33b69f-53dd-4d70-b2c1-854a4e633775
D_for_ab = 20

# ╔═╡ 8907a8e2-1412-4164-88cd-3789507b6194
one_b_values0 = 10 .^ range(-2, 0, npoints)

# ╔═╡ fd30295d-72ba-4757-8032-eebad56717a3
begin
	Random.seed!(63)
	b_errors = Dict(p => Float64[] for p in p_values)
	@progress for p in p_values[1:end-1], one_b in one_b_values0
		b = 1 - one_b
		a = b*p/(1-p)
		if 0 < a < 1
			push!(b_errors[p], estimation_error(D=D_for_ab, a=a, b=b))
		end
	end
end

# ╔═╡ 67032a61-fcc3-49b3-a68e-31c1ccf896fa
begin
	fig_b = Figure()
	ax_b = Axis(
		fig_b[1, 1],
		xlabel=L"Transition probability $1-b$",
		ylabel=L"Estimation error $||\hat{\theta} - \theta ||_{\infty}$",
		xscale=log10,
		yscale=log10,
	)
	for (k, p) in enumerate(p_values)
		p == 1 && continue
		valid_one_b_values = [
			one_b for one_b in one_b_values0 if 0 < (1-one_b)*p/(1-p) < 1
		]
		α, β = round.(
			theil_sen(log10.(valid_one_b_values), log10.(b_errors[p])),
			digits=2
		)
		scatter!(
			ax_b,
			valid_one_b_values,
			b_errors[p],
			color=p_colors[k],
			marker=p_markers[k],
			strokewidth=2,
			strokecolor=p_colors[k],
			label=L"p=%$p ~|~ \alpha=%$α"
		)
		lines!(
			ax_b,
			valid_one_b_values,
			10 .^ (α * log10.(valid_one_b_values) .+ β),
			color=p_colors[k],
		)
	end
	axislegend(ax_b)
	save(joinpath(plot_path, "influence_b.pdf"), fig_b)
	fig_b
end

# ╔═╡ 49ed15cb-207a-4a58-8911-3934ddbb6f80
md"""
## Influence of $(a, b)$
"""

# ╔═╡ 2221c55c-9332-4299-b450-f11577130325
npoints_ab = 30

# ╔═╡ 7dab4ee1-fbcb-486e-9276-cc2474176219
a_values = 10 .^ range(-1.5, 0, npoints_ab+1)[1:end-1]

# ╔═╡ 3a659443-e6ee-4dea-a9be-60ece7f83e82
one_b_values = 10 .^ range(-1.5, 0, npoints_ab+1)[1:end-1]

# ╔═╡ 751c6b7f-9a50-42d3-ac74-bae7c0a85fc8
begin
	Random.seed!(63)
	ab_errors = fill(NaN, npoints_ab, npoints_ab)
	ab_p = fill(NaN, npoints_ab, npoints_ab)
	@progress for (i, a) in enumerate(a_values), (j, one_b) in enumerate(one_b_values)
		b = 1 - one_b
		p = a / (a + b)
		ab_errors[i, j] = estimation_error(D=D_for_ab, a=a, b=b)
		ab_p[i, j] = p
	end
end

# ╔═╡ 8e113c55-d021-46f8-9414-75a996050f37
begin
	fig_ab = Figure()
	ax_ab = Axis(
		fig_ab[1, 1],
		xlabel=L"Log transition probability $\log_{10}(a)$",
		ylabel=L"Log transition probability $\log_{10}(1-b)$",
	)
	hm = contourf!(
		ax_ab,
		log10.(a_values),
		log10.(one_b_values),
		log10.(ab_errors),
		colormap=:plasma,
		levels=20
	)
	cn = contour!(
		ax_ab,
		log10.(a_values),
		log10.(one_b_values),
		log10.(ab_p),
		color="white",
		label=L"iso-$p$"
	)
	Colorbar(
		fig_ab[1, 2],
		hm,
		label=L"Log estimation error $\log_{10} ||\hat{\theta} - \theta ||_{\infty}$"
	)
	axislegend(ax_ab)
	save(joinpath(plot_path, "influence_ab.pdf"), fig_ab)
	fig_ab
end

# ╔═╡ a52bcfb9-326c-4ecd-bdc0-4c1a21b824ad
p_values_for_pb = 10 .^ range(-1, 0, npoints_ab+1)[1:end-1]

# ╔═╡ faaf2393-19f5-44d6-9277-7196b35f2d4e
begin
	Random.seed!(63)
	pb_errors = fill(NaN, npoints_ab, npoints_ab)
	@progress for (i, p) in enumerate(p_values_for_pb), (j, one_b) in enumerate(one_b_values)
		b = 1 - one_b
		a = b*p/(1-p)
		if a < 1
			pb_errors[i, j] = estimation_error(D=D_for_ab, a=a, b=b)
		end
	end
end

# ╔═╡ c16f2c5c-3d79-4e8b-89bb-cb9a3d25da21
begin
	fig_pb = Figure()
	ax_pb = Axis(
		fig_pb[1, 1],
		xlabel=L"Log sampling probability $\log_{10}(p)$",
		ylabel=L"Log transition probability $\log_{10}(1-b)$",
	)
	hm2 = contourf!(
		ax_pb,
		log10.(p_values_for_pb),
		log10.(one_b_values),
		log10.(pb_errors),
		colormap=:plasma,
		levels=20
	)
	Colorbar(
		fig_pb[1, 2],
		hm2,
		label=L"Log estimation error $\log_{10} ||\hat{\theta} - \theta ||_{\infty}$"
	)
	save(joinpath(plot_path, "influence_pb.pdf"), fig_pb)
	fig_pb
end

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
CairoMakie = "13f3f980-e62b-5c42-98c6-ff1f3baf88f0"
Clp = "e2554f3b-3117-50c0-817c-e040a3ddf72d"
Colors = "5ae59095-9a9b-59fe-a467-6f913c188581"
Distributions = "31c24e10-a181-5473-b8eb-7969acd0382f"
JuMP = "4076af6c-e467-56ae-b986-b466b2749572"
LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
ProgressLogging = "33c8b6b6-d38a-422a-b730-caa89a2f386c"
Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
Statistics = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"

[compat]
CairoMakie = "~0.6.6"
Clp = "~0.8.4"
Colors = "~0.12.8"
Distributions = "~0.25.37"
JuMP = "~0.21.5"
PlutoUI = "~0.7.27"
ProgressLogging = "~0.1.4"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.8.3"
manifest_format = "2.0"
project_hash = "5c3cafaa0f3460982e892bd9436a72fbfdee8844"

[[deps.AbstractFFTs]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "485ee0867925449198280d4af84bdb46a2a404d0"
uuid = "621f4979-c628-5d54-868e-fcf4e3e8185c"
version = "1.0.1"

[[deps.AbstractPlutoDingetjes]]
deps = ["Pkg"]
git-tree-sha1 = "8eaf9f1b4921132a4cff3f36a1d9ba923b14a481"
uuid = "6e696c72-6542-2067-7265-42206c756150"
version = "1.1.4"

[[deps.AbstractTrees]]
git-tree-sha1 = "03e0550477d86222521d254b741d470ba17ea0b5"
uuid = "1520ce14-60c1-5f80-bbc7-55ef81b5835c"
version = "0.3.4"

[[deps.Adapt]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "9faf218ea18c51fcccaf956c8d39614c9d30fe8b"
uuid = "79e6a3ab-5dfb-504d-930d-738a2a938a0e"
version = "3.3.2"

[[deps.Animations]]
deps = ["Colors"]
git-tree-sha1 = "e81c509d2c8e49592413bfb0bb3b08150056c79d"
uuid = "27a7e980-b3e6-11e9-2bcd-0b925532e340"
version = "0.4.1"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.1"

[[deps.ArrayInterface]]
deps = ["Compat", "IfElse", "LinearAlgebra", "Requires", "SparseArrays", "Static"]
git-tree-sha1 = "1ee88c4c76caa995a885dc2f22a5d548dfbbc0ba"
uuid = "4fba245c-0d91-5ea0-9b3e-6abc04ee57a9"
version = "3.2.2"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"

[[deps.Automa]]
deps = ["Printf", "ScanByte", "TranscodingStreams"]
git-tree-sha1 = "d50976f217489ce799e366d9561d56a98a30d7fe"
uuid = "67c07d97-cdcb-5c2c-af73-a7f9c32a568b"
version = "0.8.2"

[[deps.AxisAlgorithms]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "WoodburyMatrices"]
git-tree-sha1 = "66771c8d21c8ff5e3a93379480a2307ac36863f7"
uuid = "13072b0f-2c55-5437-9ae7-d433b7a33950"
version = "1.0.1"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"

[[deps.BenchmarkTools]]
deps = ["JSON", "Logging", "Printf", "Profile", "Statistics", "UUIDs"]
git-tree-sha1 = "940001114a0147b6e4d10624276d56d531dd9b49"
uuid = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
version = "1.2.2"

[[deps.BinaryProvider]]
deps = ["Libdl", "Logging", "SHA"]
git-tree-sha1 = "ecdec412a9abc8db54c0efc5548c64dfce072058"
uuid = "b99e7846-7c00-51b0-8f62-c81ae34c0232"
version = "0.5.10"

[[deps.Bzip2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "19a35467a82e236ff51bc17a3a44b69ef35185a2"
uuid = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
version = "1.0.8+0"

[[deps.CEnum]]
git-tree-sha1 = "215a9aa4a1f23fbd05b92769fdd62559488d70e9"
uuid = "fa961155-64e5-5f13-b03f-caf6b980ea82"
version = "0.4.1"

[[deps.Cairo]]
deps = ["Cairo_jll", "Colors", "Glib_jll", "Graphics", "Libdl", "Pango_jll"]
git-tree-sha1 = "d0b3f8b4ad16cb0a2988c6788646a5e6a17b6b1b"
uuid = "159f3aea-2a34-519c-b102-8c37f9878175"
version = "1.0.5"

[[deps.CairoMakie]]
deps = ["Base64", "Cairo", "Colors", "FFTW", "FileIO", "FreeType", "GeometryBasics", "LinearAlgebra", "Makie", "SHA", "StaticArrays"]
git-tree-sha1 = "774ff1cce3ae930af3948c120c15eeb96c886c33"
uuid = "13f3f980-e62b-5c42-98c6-ff1f3baf88f0"
version = "0.6.6"

[[deps.Cairo_jll]]
deps = ["Artifacts", "Bzip2_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "JLLWrappers", "LZO_jll", "Libdl", "Pixman_jll", "Pkg", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "4b859a208b2397a7a623a03449e4636bdb17bcf2"
uuid = "83423d85-b0ee-5818-9007-b63ccbeb887a"
version = "1.16.1+1"

[[deps.Calculus]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "f641eb0a4f00c343bbc32346e1217b86f3ce9dad"
uuid = "49dc2e85-a5d0-5ad3-a950-438e2897f1b9"
version = "0.5.1"

[[deps.ChainRulesCore]]
deps = ["Compat", "LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "926870acb6cbcf029396f2f2de030282b6bc1941"
uuid = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
version = "1.11.4"

[[deps.ChangesOfVariables]]
deps = ["ChainRulesCore", "LinearAlgebra", "Test"]
git-tree-sha1 = "bf98fa45a0a4cee295de98d4c1462be26345b9a1"
uuid = "9e997f8a-9a97-42d5-a9f1-ce6bfc15e2c0"
version = "0.1.2"

[[deps.Clp]]
deps = ["BinaryProvider", "CEnum", "Clp_jll", "Libdl", "MathOptInterface", "SparseArrays"]
git-tree-sha1 = "3df260c4a5764858f312ec2a17f5925624099f3a"
uuid = "e2554f3b-3117-50c0-817c-e040a3ddf72d"
version = "0.8.4"

[[deps.Clp_jll]]
deps = ["Artifacts", "CoinUtils_jll", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "METIS_jll", "MUMPS_seq_jll", "OpenBLAS32_jll", "Osi_jll", "Pkg"]
git-tree-sha1 = "b1031dcfbb44553194c9e650feb5ab65e372504f"
uuid = "06985876-5285-5a41-9fcb-8948a742cc53"
version = "100.1700.601+0"

[[deps.CodecBzip2]]
deps = ["Bzip2_jll", "Libdl", "TranscodingStreams"]
git-tree-sha1 = "2e62a725210ce3c3c2e1a3080190e7ca491f18d7"
uuid = "523fee87-0ab8-5b00-afb7-3ecf72e48cfd"
version = "0.7.2"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "ded953804d019afa9a3f98981d99b33e3db7b6da"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.0"

[[deps.CoinUtils_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "OpenBLAS32_jll", "Pkg"]
git-tree-sha1 = "44173e61256f32918c6c132fc41f772bab1fb6d1"
uuid = "be027038-0da8-5614-b30d-e42594cb92df"
version = "200.1100.400+0"

[[deps.ColorBrewer]]
deps = ["Colors", "JSON", "Test"]
git-tree-sha1 = "61c5334f33d91e570e1d0c3eb5465835242582c4"
uuid = "a2cac450-b92f-5266-8821-25eda20663c8"
version = "0.4.0"

[[deps.ColorSchemes]]
deps = ["ColorTypes", "Colors", "FixedPointNumbers", "Random"]
git-tree-sha1 = "a851fec56cb73cfdf43762999ec72eff5b86882a"
uuid = "35d6a980-a343-548e-a6ea-1d62b119f2f4"
version = "3.15.0"

[[deps.ColorTypes]]
deps = ["FixedPointNumbers", "Random"]
git-tree-sha1 = "024fe24d83e4a5bf5fc80501a314ce0d1aa35597"
uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
version = "0.11.0"

[[deps.ColorVectorSpace]]
deps = ["ColorTypes", "FixedPointNumbers", "LinearAlgebra", "SpecialFunctions", "Statistics", "TensorCore"]
git-tree-sha1 = "3f1f500312161f1ae067abe07d13b40f78f32e07"
uuid = "c3611d14-8923-5661-9e6a-0046d554d3a4"
version = "0.9.8"

[[deps.Colors]]
deps = ["ColorTypes", "FixedPointNumbers", "Reexport"]
git-tree-sha1 = "417b0ed7b8b838aa6ca0a87aadf1bb9eb111ce40"
uuid = "5ae59095-9a9b-59fe-a467-6f913c188581"
version = "0.12.8"

[[deps.CommonSubexpressions]]
deps = ["MacroTools", "Test"]
git-tree-sha1 = "7b8a93dba8af7e3b42fecabf646260105ac373f7"
uuid = "bbf7d656-a473-5ed7-a52c-81e309532950"
version = "0.3.0"

[[deps.Compat]]
deps = ["Base64", "Dates", "DelimitedFiles", "Distributed", "InteractiveUtils", "LibGit2", "Libdl", "LinearAlgebra", "Markdown", "Mmap", "Pkg", "Printf", "REPL", "Random", "SHA", "Serialization", "SharedArrays", "Sockets", "SparseArrays", "Statistics", "Test", "UUIDs", "Unicode"]
git-tree-sha1 = "44c37b4636bc54afac5c574d2d02b625349d6582"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "3.41.0"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "0.5.2+0"

[[deps.Contour]]
deps = ["StaticArrays"]
git-tree-sha1 = "9f02045d934dc030edad45944ea80dbd1f0ebea7"
uuid = "d38c429a-6771-53c6-b99e-75d170b6e991"
version = "0.5.7"

[[deps.DataAPI]]
git-tree-sha1 = "cc70b17275652eb47bc9e5f81635981f13cea5c8"
uuid = "9a962f9c-6df0-11e9-0e5d-c546b8b5ee8a"
version = "1.9.0"

[[deps.DataStructures]]
deps = ["Compat", "InteractiveUtils", "OrderedCollections"]
git-tree-sha1 = "3daef5523dd2e769dad2365274f760ff5f282c7d"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.18.11"

[[deps.DataValueInterfaces]]
git-tree-sha1 = "bfc1187b79289637fa0ef6d4436ebdfe6905cbd6"
uuid = "e2d170a0-9d28-54be-80f0-106bbe20a464"
version = "1.0.0"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

[[deps.DelimitedFiles]]
deps = ["Mmap"]
uuid = "8bb1440f-4735-579b-a4ab-409b98df4dab"

[[deps.DensityInterface]]
deps = ["InverseFunctions", "Test"]
git-tree-sha1 = "80c3e8639e3353e5d2912fb3a1916b8455e2494b"
uuid = "b429d917-457f-4dbc-8f4c-0cc954292b1d"
version = "0.4.0"

[[deps.DiffResults]]
deps = ["StaticArrays"]
git-tree-sha1 = "c18e98cba888c6c25d1c3b048e4b3380ca956805"
uuid = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
version = "1.0.3"

[[deps.DiffRules]]
deps = ["LogExpFunctions", "NaNMath", "Random", "SpecialFunctions"]
git-tree-sha1 = "9bc5dac3c8b6706b58ad5ce24cffd9861f07c94f"
uuid = "b552c78f-8df3-52c6-915a-8e097449b14b"
version = "1.9.0"

[[deps.Distributed]]
deps = ["Random", "Serialization", "Sockets"]
uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"

[[deps.Distributions]]
deps = ["ChainRulesCore", "DensityInterface", "FillArrays", "LinearAlgebra", "PDMats", "Printf", "QuadGK", "Random", "SparseArrays", "SpecialFunctions", "Statistics", "StatsBase", "StatsFuns", "Test"]
git-tree-sha1 = "6a8dc9f82e5ce28279b6e3e2cea9421154f5bd0d"
uuid = "31c24e10-a181-5473-b8eb-7969acd0382f"
version = "0.25.37"

[[deps.DocStringExtensions]]
deps = ["LibGit2"]
git-tree-sha1 = "b19534d1895d702889b219c382a6e18010797f0b"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.8.6"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.6.0"

[[deps.EarCut_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "3f3a2501fa7236e9b911e0f7a588c657e822bb6d"
uuid = "5ae413db-bbd1-5e63-b57d-d24a61df00f5"
version = "2.2.3+0"

[[deps.EllipsisNotation]]
deps = ["ArrayInterface"]
git-tree-sha1 = "3fe985505b4b667e1ae303c9ca64d181f09d5c05"
uuid = "da5c29d0-fa7d-589e-88eb-ea29b0a81949"
version = "1.1.3"

[[deps.Expat_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "b3bfd02e98aedfa5cf885665493c5598c350cd2f"
uuid = "2e619515-83b5-522b-bb60-26c02a35a201"
version = "2.2.10+0"

[[deps.FFMPEG]]
deps = ["FFMPEG_jll"]
git-tree-sha1 = "b57e3acbe22f8484b4b5ff66a7499717fe1a9cc8"
uuid = "c87230d0-a227-11e9-1b43-d7ebe4e7570a"
version = "0.4.1"

[[deps.FFMPEG_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "JLLWrappers", "LAME_jll", "Libdl", "Ogg_jll", "OpenSSL_jll", "Opus_jll", "Pkg", "Zlib_jll", "libass_jll", "libfdk_aac_jll", "libvorbis_jll", "x264_jll", "x265_jll"]
git-tree-sha1 = "d8a578692e3077ac998b50c0217dfd67f21d1e5f"
uuid = "b22a6f82-2f65-5046-a5b2-351ab43fb4e5"
version = "4.4.0+0"

[[deps.FFTW]]
deps = ["AbstractFFTs", "FFTW_jll", "LinearAlgebra", "MKL_jll", "Preferences", "Reexport"]
git-tree-sha1 = "463cb335fa22c4ebacfd1faba5fde14edb80d96c"
uuid = "7a1cc6ca-52ef-59f5-83cd-3a7055c09341"
version = "1.4.5"

[[deps.FFTW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c6033cc3892d0ef5bb9cd29b7f2f0331ea5184ea"
uuid = "f5851436-0d7a-5f13-b9de-f02708fd171a"
version = "3.3.10+0"

[[deps.FileIO]]
deps = ["Pkg", "Requires", "UUIDs"]
git-tree-sha1 = "67551df041955cc6ee2ed098718c8fcd7fc7aebe"
uuid = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
version = "1.12.0"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"

[[deps.FillArrays]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "Statistics"]
git-tree-sha1 = "8756f9935b7ccc9064c6eef0bff0ad643df733a3"
uuid = "1a297f60-69ca-5386-bcde-b61e274b549b"
version = "0.12.7"

[[deps.FixedPointNumbers]]
deps = ["Statistics"]
git-tree-sha1 = "335bfdceacc84c5cdf16aadc768aa5ddfc5383cc"
uuid = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
version = "0.8.4"

[[deps.Fontconfig_jll]]
deps = ["Artifacts", "Bzip2_jll", "Expat_jll", "FreeType2_jll", "JLLWrappers", "Libdl", "Libuuid_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "21efd19106a55620a188615da6d3d06cd7f6ee03"
uuid = "a3f928ae-7b40-5064-980b-68af3947d34b"
version = "2.13.93+0"

[[deps.Formatting]]
deps = ["Printf"]
git-tree-sha1 = "8339d61043228fdd3eb658d86c926cb282ae72a8"
uuid = "59287772-0a20-5a39-b81b-1366585eb4c0"
version = "0.4.2"

[[deps.ForwardDiff]]
deps = ["CommonSubexpressions", "DiffResults", "DiffRules", "LinearAlgebra", "LogExpFunctions", "NaNMath", "Preferences", "Printf", "Random", "SpecialFunctions", "StaticArrays"]
git-tree-sha1 = "2b72a5624e289ee18256111657663721d59c143e"
uuid = "f6369f11-7733-5829-9624-2563aa707210"
version = "0.10.24"

[[deps.FreeType]]
deps = ["CEnum", "FreeType2_jll"]
git-tree-sha1 = "cabd77ab6a6fdff49bfd24af2ebe76e6e018a2b4"
uuid = "b38be410-82b0-50bf-ab77-7b57e271db43"
version = "4.0.0"

[[deps.FreeType2_jll]]
deps = ["Artifacts", "Bzip2_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "87eb71354d8ec1a96d4a7636bd57a7347dde3ef9"
uuid = "d7e528f0-a631-5988-bf34-fe36492bcfd7"
version = "2.10.4+0"

[[deps.FreeTypeAbstraction]]
deps = ["ColorVectorSpace", "Colors", "FreeType", "GeometryBasics", "StaticArrays"]
git-tree-sha1 = "770050893e7bc8a34915b4b9298604a3236de834"
uuid = "663a7486-cb36-511b-a19d-713bb74d65c9"
version = "0.9.5"

[[deps.FriBidi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "aa31987c2ba8704e23c6c8ba8a4f769d5d7e4f91"
uuid = "559328eb-81f9-559d-9380-de523a88c83c"
version = "1.0.10+0"

[[deps.GeometryBasics]]
deps = ["EarCut_jll", "IterTools", "LinearAlgebra", "StaticArrays", "StructArrays", "Tables"]
git-tree-sha1 = "58bcdf5ebc057b085e58d95c138725628dd7453c"
uuid = "5c1252a2-5f33-56bf-86c9-59e7332b4326"
version = "0.4.1"

[[deps.Gettext_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Libiconv_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "9b02998aba7bf074d14de89f9d37ca24a1a0b046"
uuid = "78b55507-aeef-58d4-861c-77aaff3498b1"
version = "0.21.0+0"

[[deps.Glib_jll]]
deps = ["Artifacts", "Gettext_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Libiconv_jll", "Libmount_jll", "PCRE_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "a32d672ac2c967f3deb8a81d828afc739c838a06"
uuid = "7746bdde-850d-59dc-9ae8-88ece973131d"
version = "2.68.3+2"

[[deps.Graphics]]
deps = ["Colors", "LinearAlgebra", "NaNMath"]
git-tree-sha1 = "1c5a84319923bea76fa145d49e93aa4394c73fc2"
uuid = "a2bd30eb-e257-5431-a919-1863eab51364"
version = "1.1.1"

[[deps.Graphite2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "344bf40dcab1073aca04aa0df4fb092f920e4011"
uuid = "3b182d85-2403-5c21-9c21-1e1f0cc25472"
version = "1.3.14+0"

[[deps.GridLayoutBase]]
deps = ["GeometryBasics", "InteractiveUtils", "Observables"]
git-tree-sha1 = "70938436e2720e6cb8a7f2ca9f1bbdbf40d7f5d0"
uuid = "3955a311-db13-416c-9275-1d80ed98e5e9"
version = "0.6.4"

[[deps.Grisu]]
git-tree-sha1 = "53bb909d1151e57e2484c3d1b53e19552b887fb2"
uuid = "42e2da0e-8278-4e71-bc24-59509adca0fe"
version = "1.0.2"

[[deps.HTTP]]
deps = ["Base64", "Dates", "IniFile", "Logging", "MbedTLS", "NetworkOptions", "Sockets", "URIs"]
git-tree-sha1 = "0fa77022fe4b511826b39c894c90daf5fce3334a"
uuid = "cd3eb016-35fb-5094-929b-558a96fad6f3"
version = "0.9.17"

[[deps.HarfBuzz_jll]]
deps = ["Artifacts", "Cairo_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "Graphite2_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg"]
git-tree-sha1 = "129acf094d168394e80ee1dc4bc06ec835e510a3"
uuid = "2e76f6c2-a576-52d4-95c1-20adfe4de566"
version = "2.8.1+1"

[[deps.Hyperscript]]
deps = ["Test"]
git-tree-sha1 = "8d511d5b81240fc8e6802386302675bdf47737b9"
uuid = "47d2ed2b-36de-50cf-bf87-49c2cf4b8b91"
version = "0.0.4"

[[deps.HypertextLiteral]]
git-tree-sha1 = "2b078b5a615c6c0396c77810d92ee8c6f470d238"
uuid = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
version = "0.9.3"

[[deps.IOCapture]]
deps = ["Logging", "Random"]
git-tree-sha1 = "f7be53659ab06ddc986428d3a9dcc95f6fa6705a"
uuid = "b5f81e59-6552-4d32-b1f0-c071b021bf89"
version = "0.2.2"

[[deps.IfElse]]
git-tree-sha1 = "debdd00ffef04665ccbb3e150747a77560e8fad1"
uuid = "615f187c-cbe4-4ef1-ba3b-2fcf58d6d173"
version = "0.1.1"

[[deps.ImageCore]]
deps = ["AbstractFFTs", "ColorVectorSpace", "Colors", "FixedPointNumbers", "Graphics", "MappedArrays", "MosaicViews", "OffsetArrays", "PaddedViews", "Reexport"]
git-tree-sha1 = "9a5c62f231e5bba35695a20988fc7cd6de7eeb5a"
uuid = "a09fc81d-aa75-5fe9-8630-4744c3626534"
version = "0.9.3"

[[deps.ImageIO]]
deps = ["FileIO", "Netpbm", "OpenEXR", "PNGFiles", "TiffImages", "UUIDs"]
git-tree-sha1 = "a2951c93684551467265e0e32b577914f69532be"
uuid = "82e4d734-157c-48bb-816b-45c225c6df19"
version = "0.5.9"

[[deps.Imath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "87f7662e03a649cffa2e05bf19c303e168732d3e"
uuid = "905a6f67-0a94-5f89-b386-d35d92009cd1"
version = "3.1.2+0"

[[deps.IndirectArrays]]
git-tree-sha1 = "012e604e1c7458645cb8b436f8fba789a51b257f"
uuid = "9b13fd28-a010-5f03-acff-a1bbcff69959"
version = "1.0.0"

[[deps.Inflate]]
git-tree-sha1 = "f5fc07d4e706b84f72d54eedcc1c13d92fb0871c"
uuid = "d25df0c9-e2be-5dd7-82c8-3ad0b3e990b9"
version = "0.1.2"

[[deps.IniFile]]
deps = ["Test"]
git-tree-sha1 = "098e4d2c533924c921f9f9847274f2ad89e018b8"
uuid = "83e8ac13-25f8-5344-8a64-a9f2b223428f"
version = "0.5.0"

[[deps.IntelOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "d979e54b71da82f3a65b62553da4fc3d18c9004c"
uuid = "1d5cc7b8-4909-519e-a0f8-d0f5ad9712d0"
version = "2018.0.3+2"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"

[[deps.Interpolations]]
deps = ["AxisAlgorithms", "ChainRulesCore", "LinearAlgebra", "OffsetArrays", "Random", "Ratios", "Requires", "SharedArrays", "SparseArrays", "StaticArrays", "WoodburyMatrices"]
git-tree-sha1 = "b15fc0a95c564ca2e0a7ae12c1f095ca848ceb31"
uuid = "a98d9a8b-a2ab-59e6-89dd-64a1c18fca59"
version = "0.13.5"

[[deps.IntervalSets]]
deps = ["Dates", "EllipsisNotation", "Statistics"]
git-tree-sha1 = "3cc368af3f110a767ac786560045dceddfc16758"
uuid = "8197267c-284f-5f27-9208-e0e47529a953"
version = "0.5.3"

[[deps.InverseFunctions]]
deps = ["Test"]
git-tree-sha1 = "a7254c0acd8e62f1ac75ad24d5db43f5f19f3c65"
uuid = "3587e190-3f89-42d0-90ee-14403ec27112"
version = "0.1.2"

[[deps.IrrationalConstants]]
git-tree-sha1 = "7fd44fd4ff43fc60815f8e764c0f352b83c49151"
uuid = "92d709cd-6900-40b7-9082-c6be49f344b6"
version = "0.1.1"

[[deps.Isoband]]
deps = ["isoband_jll"]
git-tree-sha1 = "f9b6d97355599074dc867318950adaa6f9946137"
uuid = "f1662d9f-8043-43de-a69a-05efc1cc6ff4"
version = "0.1.1"

[[deps.IterTools]]
git-tree-sha1 = "fa6287a4469f5e048d763df38279ee729fbd44e5"
uuid = "c8e1da08-722c-5040-9ed9-7db0dc04731e"
version = "1.4.0"

[[deps.IteratorInterfaceExtensions]]
git-tree-sha1 = "a3f24677c21f5bbe9d2a714f95dcd58337fb2856"
uuid = "82899510-4779-5014-852e-03e436cf321d"
version = "1.0.0"

[[deps.JLLWrappers]]
deps = ["Preferences"]
git-tree-sha1 = "642a199af8b68253517b80bd3bfd17eb4e84df6e"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.3.0"

[[deps.JSON]]
deps = ["Dates", "Mmap", "Parsers", "Unicode"]
git-tree-sha1 = "8076680b162ada2a031f707ac7b4953e30667a37"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "0.21.2"

[[deps.JSONSchema]]
deps = ["HTTP", "JSON", "URIs"]
git-tree-sha1 = "2f49f7f86762a0fbbeef84912265a1ae61c4ef80"
uuid = "7d188eb4-7ad8-530c-ae41-71a32a6d4692"
version = "0.3.4"

[[deps.JuMP]]
deps = ["Calculus", "DataStructures", "ForwardDiff", "JSON", "LinearAlgebra", "MathOptInterface", "MutableArithmetics", "NaNMath", "Random", "SparseArrays", "Statistics"]
git-tree-sha1 = "57c17a221a55f81890aabf00f478886859e25eaf"
uuid = "4076af6c-e467-56ae-b986-b466b2749572"
version = "0.21.5"

[[deps.KernelDensity]]
deps = ["Distributions", "DocStringExtensions", "FFTW", "Interpolations", "StatsBase"]
git-tree-sha1 = "591e8dc09ad18386189610acafb970032c519707"
uuid = "5ab0869b-81aa-558d-bb23-cbf5423bbe9b"
version = "0.6.3"

[[deps.LAME_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "f6250b16881adf048549549fba48b1161acdac8c"
uuid = "c1c5ebd0-6772-5130-a774-d5fcae4a789d"
version = "3.100.1+0"

[[deps.LZO_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "e5b909bcf985c5e2605737d2ce278ed791b89be6"
uuid = "dd4b983a-f0e5-5f8d-a1b7-129d4a5fb1ac"
version = "2.10.1+0"

[[deps.LaTeXStrings]]
git-tree-sha1 = "f2355693d6778a178ade15952b7ac47a4ff97996"
uuid = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
version = "1.3.0"

[[deps.LazyArtifacts]]
deps = ["Artifacts", "Pkg"]
uuid = "4af54fe1-eca0-43a8-85a7-787d91b784e3"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.3"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "7.84.0+0"

[[deps.LibGit2]]
deps = ["Base64", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "MbedTLS_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.10.2+0"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"

[[deps.Libffi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "0b4a5d71f3e5200a7dff793393e09dfc2d874290"
uuid = "e9f186c6-92d2-5b65-8a66-fee21dc1b490"
version = "3.2.2+1"

[[deps.Libgcrypt_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgpg_error_jll", "Pkg"]
git-tree-sha1 = "64613c82a59c120435c067c2b809fc61cf5166ae"
uuid = "d4300ac3-e22c-5743-9152-c294e39db1e4"
version = "1.8.7+0"

[[deps.Libgpg_error_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c333716e46366857753e273ce6a69ee0945a6db9"
uuid = "7add5ba3-2f88-524e-9cd5-f83b8a55f7b8"
version = "1.42.0+0"

[[deps.Libiconv_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "42b62845d70a619f063a7da093d995ec8e15e778"
uuid = "94ce4f54-9a6c-5748-9c1c-f9c7231a4531"
version = "1.16.1+1"

[[deps.Libmount_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9c30530bf0effd46e15e0fdcf2b8636e78cbbd73"
uuid = "4b2f31a3-9ecc-558c-b454-b3730dcb73e9"
version = "2.35.0+0"

[[deps.Libuuid_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "7f3efec06033682db852f8b3bc3c1d2b0a0ab066"
uuid = "38a345b3-de98-5d2b-a5d3-14cd9215e700"
version = "2.36.0+0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

[[deps.LogExpFunctions]]
deps = ["ChainRulesCore", "ChangesOfVariables", "DocStringExtensions", "InverseFunctions", "IrrationalConstants", "LinearAlgebra"]
git-tree-sha1 = "e5718a00af0ab9756305a0392832c8952c7426c1"
uuid = "2ab3a3ac-af41-5b50-aa03-7779005ae688"
version = "0.3.6"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"

[[deps.METIS_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "1d31872bb9c5e7ec1f618e8c4a56c8b0d9bddc7e"
uuid = "d00139f3-1899-568f-a2f0-47f597d42d70"
version = "5.1.1+0"

[[deps.MKL_jll]]
deps = ["Artifacts", "IntelOpenMP_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "Pkg"]
git-tree-sha1 = "5455aef09b40e5020e1520f551fa3135040d4ed0"
uuid = "856f044c-d86e-5d09-b602-aeab76dc8ba7"
version = "2021.1.1+2"

[[deps.MUMPS_seq_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "METIS_jll", "OpenBLAS32_jll", "Pkg"]
git-tree-sha1 = "29de2841fa5aefe615dea179fcde48bb87b58f57"
uuid = "d7ed1dd3-d0ae-5e8e-bfb4-87a502085b8d"
version = "5.4.1+0"

[[deps.MacroTools]]
deps = ["Markdown", "Random"]
git-tree-sha1 = "3d3e902b31198a27340d0bf00d6ac452866021cf"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.9"

[[deps.Makie]]
deps = ["Animations", "Base64", "ColorBrewer", "ColorSchemes", "ColorTypes", "Colors", "Contour", "Distributions", "DocStringExtensions", "FFMPEG", "FileIO", "FixedPointNumbers", "Formatting", "FreeType", "FreeTypeAbstraction", "GeometryBasics", "GridLayoutBase", "ImageIO", "IntervalSets", "Isoband", "KernelDensity", "LaTeXStrings", "LinearAlgebra", "MakieCore", "Markdown", "Match", "MathTeXEngine", "Observables", "Packing", "PlotUtils", "PolygonOps", "Printf", "Random", "RelocatableFolders", "Serialization", "Showoff", "SignedDistanceFields", "SparseArrays", "StaticArrays", "Statistics", "StatsBase", "StatsFuns", "StructArrays", "UnicodeFun"]
git-tree-sha1 = "56b0b7772676c499430dc8eb15cfab120c05a150"
uuid = "ee78f7c6-11fb-53f2-987a-cfe4a2b5a57a"
version = "0.15.3"

[[deps.MakieCore]]
deps = ["Observables"]
git-tree-sha1 = "7bcc8323fb37523a6a51ade2234eee27a11114c8"
uuid = "20f20a25-4f0e-4fdf-b5d1-57303727442b"
version = "0.1.3"

[[deps.MappedArrays]]
git-tree-sha1 = "e8b359ef06ec72e8c030463fe02efe5527ee5142"
uuid = "dbb5928d-eab1-5f90-85c2-b9b0edb7c900"
version = "0.4.1"

[[deps.Markdown]]
deps = ["Base64"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"

[[deps.Match]]
git-tree-sha1 = "1d9bc5c1a6e7ee24effb93f175c9342f9154d97f"
uuid = "7eb4fadd-790c-5f42-8a69-bfa0b872bfbf"
version = "1.2.0"

[[deps.MathOptInterface]]
deps = ["BenchmarkTools", "CodecBzip2", "CodecZlib", "JSON", "JSONSchema", "LinearAlgebra", "MutableArithmetics", "OrderedCollections", "SparseArrays", "Test", "Unicode"]
git-tree-sha1 = "575644e3c05b258250bb599e57cf73bbf1062901"
uuid = "b8f27783-ece8-5eb3-8dc8-9495eed66fee"
version = "0.9.22"

[[deps.MathTeXEngine]]
deps = ["AbstractTrees", "Automa", "DataStructures", "FreeTypeAbstraction", "GeometryBasics", "LaTeXStrings", "REPL", "RelocatableFolders", "Test"]
git-tree-sha1 = "70e733037bbf02d691e78f95171a1fa08cdc6332"
uuid = "0a4f8689-d25c-4efe-a92b-7142dfc1aa53"
version = "0.2.1"

[[deps.MbedTLS]]
deps = ["Dates", "MbedTLS_jll", "Random", "Sockets"]
git-tree-sha1 = "1c38e51c3d08ef2278062ebceade0e46cefc96fe"
uuid = "739be429-bea8-5141-9913-cc70e7f3736d"
version = "1.0.3"

[[deps.MbedTLS_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "c8ffd9c3-330d-5841-b78e-0817d7145fa1"
version = "2.28.0+0"

[[deps.Missings]]
deps = ["DataAPI"]
git-tree-sha1 = "bf210ce90b6c9eed32d25dbcae1ebc565df2687f"
uuid = "e1d29d7a-bbdc-5cf2-9ac0-f12de2c33e28"
version = "1.0.2"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"

[[deps.MosaicViews]]
deps = ["MappedArrays", "OffsetArrays", "PaddedViews", "StackViews"]
git-tree-sha1 = "b34e3bc3ca7c94914418637cb10cc4d1d80d877d"
uuid = "e94cdb99-869f-56ef-bcf0-1ae2bcbe0389"
version = "0.3.3"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2022.2.1"

[[deps.MutableArithmetics]]
deps = ["LinearAlgebra", "SparseArrays", "Test"]
git-tree-sha1 = "8d9496b2339095901106961f44718920732616bb"
uuid = "d8a4904e-b15c-11e9-3269-09a3773c0cb0"
version = "0.2.22"

[[deps.NaNMath]]
git-tree-sha1 = "f755f36b19a5116bb580de457cda0c140153f283"
uuid = "77ba4419-2d1f-58cd-9bb1-8ffee604a2e3"
version = "0.3.6"

[[deps.Netpbm]]
deps = ["FileIO", "ImageCore"]
git-tree-sha1 = "18efc06f6ec36a8b801b23f076e3c6ac7c3bf153"
uuid = "f09324ee-3d7c-5217-9330-fc30815ba969"
version = "1.0.2"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.2.0"

[[deps.Observables]]
git-tree-sha1 = "fe29afdef3d0c4a8286128d4e45cc50621b1e43d"
uuid = "510215fc-4207-5dde-b226-833fc4488ee2"
version = "0.4.0"

[[deps.OffsetArrays]]
deps = ["Adapt"]
git-tree-sha1 = "043017e0bdeff61cfbb7afeb558ab29536bbb5ed"
uuid = "6fe1bfb0-de20-5000-8ca7-80f57d26f881"
version = "1.10.8"

[[deps.Ogg_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "887579a3eb005446d514ab7aeac5d1d027658b8f"
uuid = "e7412a2a-1a6e-54c0-be00-318e2571c051"
version = "1.3.5+1"

[[deps.OpenBLAS32_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9c6c2ed4b7acd2137b878eb96c68e63b76199d0f"
uuid = "656ef2d0-ae68-5445-9ca0-591084a874a2"
version = "0.3.17+0"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.20+0"

[[deps.OpenEXR]]
deps = ["Colors", "FileIO", "OpenEXR_jll"]
git-tree-sha1 = "327f53360fdb54df7ecd01e96ef1983536d1e633"
uuid = "52e1d378-f018-4a11-a4be-720524705ac7"
version = "0.3.2"

[[deps.OpenEXR_jll]]
deps = ["Artifacts", "Imath_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "923319661e9a22712f24596ce81c54fc0366f304"
uuid = "18a262bb-aa17-5467-a713-aee519bc75cb"
version = "3.1.1+0"

[[deps.OpenLibm_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "05823500-19ac-5b8b-9628-191a04bc5112"
version = "0.8.1+0"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "15003dcb7d8db3c6c857fda14891a539a8f2705a"
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "1.1.10+0"

[[deps.OpenSpecFun_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "13652491f6856acfd2db29360e1bbcd4565d04f1"
uuid = "efe28fd5-8261-553b-a9e1-b2916fc3738e"
version = "0.5.5+0"

[[deps.Opus_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "51a08fb14ec28da2ec7a927c4337e4332c2a4720"
uuid = "91d4177d-7536-5919-b921-800302f37372"
version = "1.3.2+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "85f8e6578bf1f9ee0d11e7bb1b1456435479d47c"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "1.4.1"

[[deps.Osi_jll]]
deps = ["Artifacts", "CoinUtils_jll", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "OpenBLAS32_jll", "Pkg"]
git-tree-sha1 = "28e0ddebd069f605ab1988ab396f239a3ac9b561"
uuid = "7da25872-d9ce-5375-a4d3-7a845f58efdd"
version = "0.10800.600+0"

[[deps.PCRE_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "b2a7af664e098055a7529ad1a900ded962bca488"
uuid = "2f80f16e-611a-54ab-bc61-aa92de5b98fc"
version = "8.44.0+0"

[[deps.PDMats]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "ee26b350276c51697c9c2d88a072b339f9f03d73"
uuid = "90014a1f-27ba-587c-ab20-58faa44d9150"
version = "0.11.5"

[[deps.PNGFiles]]
deps = ["Base64", "CEnum", "ImageCore", "IndirectArrays", "OffsetArrays", "libpng_jll"]
git-tree-sha1 = "6d105d40e30b635cfed9d52ec29cf456e27d38f8"
uuid = "f57f5aa1-a3ce-4bc8-8ab9-96f992907883"
version = "0.3.12"

[[deps.Packing]]
deps = ["GeometryBasics"]
git-tree-sha1 = "1155f6f937fa2b94104162f01fa400e192e4272f"
uuid = "19eb6ba3-879d-56ad-ad62-d5c202156566"
version = "0.4.2"

[[deps.PaddedViews]]
deps = ["OffsetArrays"]
git-tree-sha1 = "03a7a85b76381a3d04c7a1656039197e70eda03d"
uuid = "5432bcbf-9aad-5242-b902-cca2824c8663"
version = "0.5.11"

[[deps.Pango_jll]]
deps = ["Artifacts", "Cairo_jll", "Fontconfig_jll", "FreeType2_jll", "FriBidi_jll", "Glib_jll", "HarfBuzz_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9bc1871464b12ed19297fbc56c4fb4ba84988b0d"
uuid = "36c8627f-9965-5494-a995-c6b170f724f3"
version = "1.47.0+0"

[[deps.Parsers]]
deps = ["Dates"]
git-tree-sha1 = "d7fa6237da8004be601e19bd6666083056649918"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.1.3"

[[deps.Pixman_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "b4f5d02549a10e20780a24fce72bea96b6329e29"
uuid = "30392449-352a-5448-841d-b1acce4e97dc"
version = "0.40.1+0"

[[deps.Pkg]]
deps = ["Artifacts", "Dates", "Downloads", "LibGit2", "Libdl", "Logging", "Markdown", "Printf", "REPL", "Random", "SHA", "Serialization", "TOML", "Tar", "UUIDs", "p7zip_jll"]
uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
version = "1.8.0"

[[deps.PkgVersion]]
deps = ["Pkg"]
git-tree-sha1 = "a7a7e1a88853564e551e4eba8650f8c38df79b37"
uuid = "eebad327-c553-4316-9ea0-9fa01ccd7688"
version = "0.1.1"

[[deps.PlotUtils]]
deps = ["ColorSchemes", "Colors", "Dates", "Printf", "Random", "Reexport", "Statistics"]
git-tree-sha1 = "68604313ed59f0408313228ba09e79252e4b2da8"
uuid = "995b91a9-d308-5afd-9ec6-746e21dbc043"
version = "1.1.2"

[[deps.PlutoUI]]
deps = ["AbstractPlutoDingetjes", "Base64", "ColorTypes", "Dates", "Hyperscript", "HypertextLiteral", "IOCapture", "InteractiveUtils", "JSON", "Logging", "Markdown", "Random", "Reexport", "UUIDs"]
git-tree-sha1 = "fed057115644d04fba7f4d768faeeeff6ad11a60"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.27"

[[deps.PolygonOps]]
git-tree-sha1 = "77b3d3605fc1cd0b42d95eba87dfcd2bf67d5ff6"
uuid = "647866c9-e3ac-4575-94e7-e3d426903924"
version = "0.1.2"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "2cf929d64681236a2e074ffafb8d568733d2e6af"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.2.3"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"

[[deps.Profile]]
deps = ["Printf"]
uuid = "9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"

[[deps.ProgressLogging]]
deps = ["Logging", "SHA", "UUIDs"]
git-tree-sha1 = "80d919dee55b9c50e8d9e2da5eeafff3fe58b539"
uuid = "33c8b6b6-d38a-422a-b730-caa89a2f386c"
version = "0.1.4"

[[deps.ProgressMeter]]
deps = ["Distributed", "Printf"]
git-tree-sha1 = "afadeba63d90ff223a6a48d2009434ecee2ec9e8"
uuid = "92933f4c-e287-5a05-a399-4b506db050ca"
version = "1.7.1"

[[deps.QuadGK]]
deps = ["DataStructures", "LinearAlgebra"]
git-tree-sha1 = "78aadffb3efd2155af139781b8a8df1ef279ea39"
uuid = "1fd47b50-473d-5c70-9696-f719f8f3bcdc"
version = "2.4.2"

[[deps.REPL]]
deps = ["InteractiveUtils", "Markdown", "Sockets", "Unicode"]
uuid = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

[[deps.Random]]
deps = ["SHA", "Serialization"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"

[[deps.Ratios]]
deps = ["Requires"]
git-tree-sha1 = "01d341f502250e81f6fec0afe662aa861392a3aa"
uuid = "c84ed2f1-dad5-54f0-aa8e-dbefe2724439"
version = "0.4.2"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.RelocatableFolders]]
deps = ["SHA", "Scratch"]
git-tree-sha1 = "cdbd3b1338c72ce29d9584fdbe9e9b70eeb5adca"
uuid = "05181044-ff0b-4ac5-8273-598c1e38db00"
version = "0.1.3"

[[deps.Requires]]
deps = ["UUIDs"]
git-tree-sha1 = "8f82019e525f4d5c669692772a6f4b0a58b06a6a"
uuid = "ae029012-a4dd-5104-9daa-d747884805df"
version = "1.2.0"

[[deps.Rmath]]
deps = ["Random", "Rmath_jll"]
git-tree-sha1 = "bf3188feca147ce108c76ad82c2792c57abe7b1f"
uuid = "79098fc4-a85e-5d69-aa6a-4863f24498fa"
version = "0.7.0"

[[deps.Rmath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "68db32dff12bb6127bac73c209881191bf0efbb7"
uuid = "f50d1b31-88e8-58de-be2c-1cc44531875f"
version = "0.3.0+0"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.SIMD]]
git-tree-sha1 = "9ba33637b24341aba594a2783a502760aa0bff04"
uuid = "fdea26ae-647d-5447-a871-4b548cad5224"
version = "3.3.1"

[[deps.ScanByte]]
deps = ["Libdl", "SIMD"]
git-tree-sha1 = "9cc2955f2a254b18be655a4ee70bc4031b2b189e"
uuid = "7b38b023-a4d7-4c5e-8d43-3f3097f304eb"
version = "0.3.0"

[[deps.Scratch]]
deps = ["Dates"]
git-tree-sha1 = "0b4b7f1393cff97c33891da2a0bf69c6ed241fda"
uuid = "6c6a2e73-6563-6170-7368-637461726353"
version = "1.1.0"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"

[[deps.SharedArrays]]
deps = ["Distributed", "Mmap", "Random", "Serialization"]
uuid = "1a1011a3-84de-559e-8e89-a11a2f7dc383"

[[deps.Showoff]]
deps = ["Dates", "Grisu"]
git-tree-sha1 = "91eddf657aca81df9ae6ceb20b959ae5653ad1de"
uuid = "992d4aef-0814-514b-bc4d-f2e9a6c4116f"
version = "1.0.3"

[[deps.SignedDistanceFields]]
deps = ["Random", "Statistics", "Test"]
git-tree-sha1 = "d263a08ec505853a5ff1c1ebde2070419e3f28e9"
uuid = "73760f76-fbc4-59ce-8f25-708e95d2df96"
version = "0.4.0"

[[deps.Sockets]]
uuid = "6462fe0b-24de-5631-8697-dd941f90decc"

[[deps.SortingAlgorithms]]
deps = ["DataStructures"]
git-tree-sha1 = "b3363d7460f7d098ca0912c69b082f75625d7508"
uuid = "a2af1166-a08f-5f64-846c-94a0d3cef48c"
version = "1.0.1"

[[deps.SparseArrays]]
deps = ["LinearAlgebra", "Random"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"

[[deps.SpecialFunctions]]
deps = ["ChainRulesCore", "IrrationalConstants", "LogExpFunctions", "OpenLibm_jll", "OpenSpecFun_jll"]
git-tree-sha1 = "e08890d19787ec25029113e88c34ec20cac1c91e"
uuid = "276daf66-3868-5448-9aa4-cd146d93841b"
version = "2.0.0"

[[deps.StackViews]]
deps = ["OffsetArrays"]
git-tree-sha1 = "46e589465204cd0c08b4bd97385e4fa79a0c770c"
uuid = "cae243ae-269e-4f55-b966-ac2d0dc13c15"
version = "0.1.1"

[[deps.Static]]
deps = ["IfElse"]
git-tree-sha1 = "7f5a513baec6f122401abfc8e9c074fdac54f6c1"
uuid = "aedffcd0-7271-4cad-89d0-dc628f76c6d3"
version = "0.4.1"

[[deps.StaticArrays]]
deps = ["LinearAlgebra", "Random", "Statistics"]
git-tree-sha1 = "de9e88179b584ba9cf3cc5edbb7a41f26ce42cda"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
version = "1.3.0"

[[deps.Statistics]]
deps = ["LinearAlgebra", "SparseArrays"]
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"

[[deps.StatsAPI]]
git-tree-sha1 = "d88665adc9bcf45903013af0982e2fd05ae3d0a6"
uuid = "82ae8749-77ed-4fe6-ae5f-f523153014b0"
version = "1.2.0"

[[deps.StatsBase]]
deps = ["DataAPI", "DataStructures", "LinearAlgebra", "LogExpFunctions", "Missings", "Printf", "Random", "SortingAlgorithms", "SparseArrays", "Statistics", "StatsAPI"]
git-tree-sha1 = "51383f2d367eb3b444c961d485c565e4c0cf4ba0"
uuid = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91"
version = "0.33.14"

[[deps.StatsFuns]]
deps = ["ChainRulesCore", "InverseFunctions", "IrrationalConstants", "LogExpFunctions", "Reexport", "Rmath", "SpecialFunctions"]
git-tree-sha1 = "bedb3e17cc1d94ce0e6e66d3afa47157978ba404"
uuid = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
version = "0.9.14"

[[deps.StructArrays]]
deps = ["Adapt", "DataAPI", "StaticArrays", "Tables"]
git-tree-sha1 = "2ce41e0d042c60ecd131e9fb7154a3bfadbf50d3"
uuid = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
version = "0.6.3"

[[deps.SuiteSparse]]
deps = ["Libdl", "LinearAlgebra", "Serialization", "SparseArrays"]
uuid = "4607b0f0-06f3-5cda-b6b1-a6196a1729e9"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.0"

[[deps.TableTraits]]
deps = ["IteratorInterfaceExtensions"]
git-tree-sha1 = "c06b2f539df1c6efa794486abfb6ed2022561a39"
uuid = "3783bdb8-4a98-5b6b-af9a-565f29a5fe9c"
version = "1.0.1"

[[deps.Tables]]
deps = ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "LinearAlgebra", "TableTraits", "Test"]
git-tree-sha1 = "bb1064c9a84c52e277f1096cf41434b675cd368b"
uuid = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
version = "1.6.1"

[[deps.Tar]]
deps = ["ArgTools", "SHA"]
uuid = "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"
version = "1.10.1"

[[deps.TensorCore]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1feb45f88d133a655e001435632f019a9a1bcdb6"
uuid = "62fd8b95-f654-4bbd-a8a5-9c27f68ccd50"
version = "0.1.1"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.TiffImages]]
deps = ["ColorTypes", "DataStructures", "DocStringExtensions", "FileIO", "FixedPointNumbers", "IndirectArrays", "Inflate", "OffsetArrays", "PkgVersion", "ProgressMeter", "UUIDs"]
git-tree-sha1 = "991d34bbff0d9125d93ba15887d6594e8e84b305"
uuid = "731e570b-9d59-4bfa-96dc-6df516fadf69"
version = "0.5.3"

[[deps.TranscodingStreams]]
deps = ["Random", "Test"]
git-tree-sha1 = "216b95ea110b5972db65aa90f88d8d89dcb8851c"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.9.6"

[[deps.URIs]]
git-tree-sha1 = "97bbe755a53fe859669cd907f2d96aee8d2c1355"
uuid = "5c2747f8-b7ea-4ff2-ba2e-563bfd36b1d4"
version = "1.3.0"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"

[[deps.UnicodeFun]]
deps = ["REPL"]
git-tree-sha1 = "53915e50200959667e78a92a418594b428dffddf"
uuid = "1cfade01-22cf-5700-b092-accc4b62d6e1"
version = "0.4.1"

[[deps.WoodburyMatrices]]
deps = ["LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "de67fa59e33ad156a590055375a30b23c40299d3"
uuid = "efce3f68-66dc-5838-9240-27a6d6f5f9b6"
version = "0.5.5"

[[deps.XML2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libiconv_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "1acf5bdf07aa0907e0a37d3718bb88d4b687b74a"
uuid = "02c8fc9c-b97f-50b9-bbe4-9be30ff0a78a"
version = "2.9.12+0"

[[deps.XSLT_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgcrypt_jll", "Libgpg_error_jll", "Libiconv_jll", "Pkg", "XML2_jll", "Zlib_jll"]
git-tree-sha1 = "91844873c4085240b95e795f692c4cec4d805f8a"
uuid = "aed1982a-8fda-507f-9586-7b0439959a61"
version = "1.1.34+0"

[[deps.Xorg_libX11_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libxcb_jll", "Xorg_xtrans_jll"]
git-tree-sha1 = "5be649d550f3f4b95308bf0183b82e2582876527"
uuid = "4f6342f7-b3d2-589e-9d20-edeb45f2b2bc"
version = "1.6.9+4"

[[deps.Xorg_libXau_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4e490d5c960c314f33885790ed410ff3a94ce67e"
uuid = "0c0b7dd1-d40b-584c-a123-a41640f87eec"
version = "1.0.9+4"

[[deps.Xorg_libXdmcp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4fe47bd2247248125c428978740e18a681372dd4"
uuid = "a3789734-cfe1-5b06-b2d0-1dd0d9d62d05"
version = "1.1.3+4"

[[deps.Xorg_libXext_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "b7c0aa8c376b31e4852b360222848637f481f8c3"
uuid = "1082639a-0dae-5f34-9b06-72781eeb8cb3"
version = "1.3.4+4"

[[deps.Xorg_libXrender_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "19560f30fd49f4d4efbe7002a1037f8c43d43b96"
uuid = "ea2f1a96-1ddc-540d-b46f-429655e07cfa"
version = "0.9.10+4"

[[deps.Xorg_libpthread_stubs_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "6783737e45d3c59a4a4c4091f5f88cdcf0908cbb"
uuid = "14d82f49-176c-5ed1-bb49-ad3f5cbd8c74"
version = "0.1.0+3"

[[deps.Xorg_libxcb_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "XSLT_jll", "Xorg_libXau_jll", "Xorg_libXdmcp_jll", "Xorg_libpthread_stubs_jll"]
git-tree-sha1 = "daf17f441228e7a3833846cd048892861cff16d6"
uuid = "c7cfdc94-dc32-55de-ac96-5a1b8d977c5b"
version = "1.13.0+3"

[[deps.Xorg_xtrans_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "79c31e7844f6ecf779705fbc12146eb190b7d845"
uuid = "c5fb5394-a638-5e4d-96e5-b29de1b5cf10"
version = "1.4.0+3"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.2.12+3"

[[deps.isoband_jll]]
deps = ["Libdl", "Pkg"]
git-tree-sha1 = "a1ac99674715995a536bbce674b068ec1b7d893d"
uuid = "9a68df92-36a6-505f-a73e-abb412b6bfb4"
version = "0.2.2+0"

[[deps.libass_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "HarfBuzz_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "5982a94fcba20f02f42ace44b9894ee2b140fe47"
uuid = "0ac62f75-1d6f-5e53-bd7c-93b484bb37c0"
version = "0.15.1+0"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl", "OpenBLAS_jll"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.1.1+0"

[[deps.libfdk_aac_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "daacc84a041563f965be61859a36e17c4e4fcd55"
uuid = "f638f0a6-7fb0-5443-88ba-1cc74229b280"
version = "2.0.2+0"

[[deps.libpng_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "94d180a6d2b5e55e447e2d27a29ed04fe79eb30c"
uuid = "b53b4c65-9356-5827-b1ea-8c7a1a84506f"
version = "1.6.38+0"

[[deps.libvorbis_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Ogg_jll", "Pkg"]
git-tree-sha1 = "b910cb81ef3fe6e78bf6acee440bda86fd6ae00c"
uuid = "f27f6e37-5d2b-51aa-960f-b287f2bc3b7a"
version = "1.3.7+1"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.48.0+0"

[[deps.p7zip_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "3f19e933-33d8-53b3-aaab-bd5110c3b7a0"
version = "17.4.0+0"

[[deps.x264_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4fea590b89e6ec504593146bf8b988b2c00922b2"
uuid = "1270edf5-f2f9-52d2-97e9-ab00b5d0237a"
version = "2021.5.5+0"

[[deps.x265_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "ee567a171cce03570d77ad3a43e90218e38937a9"
uuid = "dfaa095f-4041-5dcd-9319-2fabd8486b76"
version = "3.5.0+0"
"""

# ╔═╡ Cell order:
# ╠═cc48914c-6e47-11ec-2ebb-a734d4f5f9fc
# ╠═8844d3f8-8317-4e7b-98fe-da3403be173c
# ╠═8acaf22f-1d73-4d20-a489-7e2851fb7a08
# ╟─8e89c07e-c324-46ca-bdee-14ee9d366220
# ╟─1a3ebfe0-2bae-4e7c-8bfc-0ec9717f303b
# ╟─01676dff-d535-4acd-9d28-85221e1d34f7
# ╟─2fcdb163-f32c-4dd5-87ff-d463fd521ce4
# ╠═b641ffb3-d1ad-40e2-be79-bac2dddde8cf
# ╠═934fa46d-3b64-48fe-a325-72bf1a453dcc
# ╟─c3f1ddbf-2670-4705-ae5d-6bb419e9fef2
# ╠═084dcbd4-f677-44c7-9fc1-03bf43efab79
# ╠═40937800-850a-4ebe-8b13-a84c1e38a973
# ╠═d20e47e7-b002-4d1a-89bd-2221032c7190
# ╠═bf02237e-8a46-4bbf-8f3e-01b518680c57
# ╠═7c66f7a5-e8b1-40af-aa42-9b88bd17abb7
# ╠═dffa0866-6d21-4665-8013-92bbeaab7b69
# ╟─f3744ba6-4f83-4a8b-acae-e539b043023d
# ╠═d6b5a773-40bc-4c7f-a2d5-5f83a7c5faed
# ╠═c28202b4-09c7-4c91-81e8-58bbad6ea08f
# ╠═65a20d43-3eb4-4dc5-a7e3-35a997ba34f6
# ╠═026629b2-7fae-441e-a2cc-c6e21f000d90
# ╠═faf615b2-d17b-48e3-891b-46db7bd4245b
# ╟─cb0cd770-9aec-463f-ba2f-a04c712a2e62
# ╠═bbb959dd-74c8-4924-9eee-52ea4c67cc3e
# ╠═9288b659-c784-48ea-9110-5cf33f68179b
# ╠═be6db533-e3d4-4d96-bc90-8063db960a7f
# ╟─f35c9fd1-be04-47f9-a390-4ed891c9e616
# ╠═758f7227-e647-4378-bae7-98267f977ba3
# ╠═66fb58c0-c7ef-4e14-b73a-c869d9962cc1
# ╠═99801229-d58b-41a1-aae7-fd672f9b0f97
# ╟─56c6cd18-fbc3-47e5-945c-53fd6293c6b6
# ╠═602588a7-1989-4dd3-a66a-e5f6bf72f904
# ╠═a214165b-2903-42a0-88f1-ecd0f3a90e82
# ╠═8b554763-8a84-4497-b5c1-2f5e3a41b96e
# ╟─5d398ec9-13db-4a29-bf20-8551e757d92c
# ╠═db0e8104-918c-46a0-9f50-920b44474dcd
# ╠═7c0fbd79-e9c2-49b3-98c4-f67bb730d49e
# ╠═dd47d8a8-b379-4cc5-991d-6df0d0f6fcb7
# ╠═16ae6f4e-d74d-4263-9ca8-b2b14ec71d3a
# ╟─5781a0d3-428d-410f-8acb-5cd1a39118a1
# ╠═aef4d77b-ee37-4f27-b350-7939520f0e48
# ╠═29d1d386-52ca-4ff5-93a7-d4eeda1d758f
# ╠═cf97f7df-3930-4fc8-8077-6379a7365e5c
# ╠═a1c9b17b-a5b5-43a0-824d-64b7de26be76
# ╟─3e99926b-bcba-4446-9485-c14e02aaf880
# ╠═4f3ff83f-56b9-42b7-9844-cebf8eea9323
# ╠═0ecd2072-8669-48c3-90c4-eea124a7b164
# ╠═eb014af1-18e4-4eda-8a65-7c8d630c3054
# ╠═f033f1d8-24c6-4d82-8ada-599916dc5ff6
# ╠═dc8c82bd-7074-46e4-b574-1f6a3b810cd9
# ╠═5595ed61-e5f1-4686-b8f6-9c3587270ea5
# ╟─2c7f8e1b-66af-4d40-8aef-7a2c6ea3ad03
# ╠═3a33b69f-53dd-4d70-b2c1-854a4e633775
# ╠═8907a8e2-1412-4164-88cd-3789507b6194
# ╠═fd30295d-72ba-4757-8032-eebad56717a3
# ╠═67032a61-fcc3-49b3-a68e-31c1ccf896fa
# ╟─49ed15cb-207a-4a58-8911-3934ddbb6f80
# ╠═2221c55c-9332-4299-b450-f11577130325
# ╠═7dab4ee1-fbcb-486e-9276-cc2474176219
# ╠═3a659443-e6ee-4dea-a9be-60ece7f83e82
# ╠═751c6b7f-9a50-42d3-ac74-bae7c0a85fc8
# ╠═8e113c55-d021-46f8-9414-75a996050f37
# ╠═a52bcfb9-326c-4ecd-bdc0-4c1a21b824ad
# ╠═faaf2393-19f5-44d6-9277-7196b35f2d4e
# ╠═c16f2c5c-3d79-4e8b-89bb-cb9a3d25da21
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
