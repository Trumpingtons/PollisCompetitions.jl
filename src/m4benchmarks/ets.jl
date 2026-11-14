# Exponential smoothing with additive errors, fitted as R's forecast 8.2 fits it in `ses` and `holt`: `ets` with the
# model ANN or AAN (damped or not), the criterion "mse" and the bounds "both". The starting values are those of
# `initparam` and `initstate` of forecast 8.2, the recursions those of `etscalc.c`, and the optimiser is R's Nelder-Mead
# (`nmmin` of `optim.c`), with the tolerances `ets` gives it.

"""The bounds of the smoothing parameters alpha, beta and phi in `ets` of R's forecast."""
const LOWER = (alpha = 0.0001, beta = 0.0001, phi = 0.8)
const UPPER = (alpha = 0.9999, beta = 0.9999, phi = 0.98)

"""The most evaluations of the objective `ets` allows its optimiser."""
const MAXIT = 2000

"""The value R's Nelder-Mead puts in place of an objective that is not finite."""
const BIG = 1.0e35

"""
The value `etscalc.c` gives a forecast it cannot compute (`NA`), of a multiplicative trend; never reached by the
additive models here, but kept as the C code keeps it.
"""
const NA = -99999.0

"""The mean as R computes it: the sum over the count, corrected by the mean of the deviations from it."""
function r_mean(values)
	total = 0.0
	for value in values
		total += value
	end
	mean = total / length(values)
	isfinite(mean) || return mean
	deviation = 0.0
	for value in values
		deviation += value - mean
	end
	mean + deviation / length(values)
end

"""The Euclidean norm of `x` as `dnrm2` of the reference BLAS computes it, scaled against overflow."""
function norm2(x)
	length(x) == 0 && return 0.0
	length(x) == 1 && return abs(x[1])
	scale, squares = 0.0, 1.0
	for value in x
		if value != 0
			magnitude = abs(value)
			if scale < magnitude
				squares = 1.0 + squares * (scale / magnitude)^2
				scale = magnitude
			else
				squares += (magnitude / scale)^2
			end
		end
	end
	scale * sqrt(squares)
end

"""The inner product of `x` and `y` as `ddot` of the reference BLAS computes it, term after term."""
function inner(x, y)
	total = 0.0
	for i in eachindex(x, y)
		total += x[i] * y[i]
	end
	total
end

"""
	least_squares(x, y)

The intercept and the slope of the least squares line of `y` on `x`, as R's `lsfit` and `lm` compute them: the
Householder QR decomposition of LINPACK (`dqrdc2`, then `dqrsl`), operation for operation, so that the starting
values of `holt` and the line of `theta` are R's to the last digit.
"""
function least_squares(x, y)
	n = length(y)
	X = [ones(n) Float64.(x)]
	qraux = [norm2(view(X, :, 1)), norm2(view(X, :, 2))]
	for l in 1:min(n, 2)
		l == n && break
		column = view(X, l:n, l)
		norm = norm2(column)
		norm == 0 && continue
		X[l, l] != 0 && (norm = copysign(norm, X[l, l]))
		column .*= 1.0 / norm
		X[l, l] = 1.0 + X[l, l]
		for j in (l + 1):2
			other = view(X, l:n, j)
			t = -inner(column, other) / X[l, l]
			other .+= t .* column
			if qraux[j] != 0
				remaining = max(1.0 - (abs(X[l, j]) / qraux[j])^2, 0.0)
				qraux[j] = abs(remaining) < 1e-6 ? norm2(view(X, (l + 1):n, j)) : qraux[j] * sqrt(remaining)
			end
		end
		qraux[l] = X[l, l]
		X[l, l] = -norm
	end
	rotated = Float64.(y)
	for j in 1:min(2, n - 1)
		qraux[j] == 0 && continue
		diagonal = X[j, j]
		X[j, j] = qraux[j]
		t = -inner(view(X, j:n, j), view(rotated, j:n)) / X[j, j]
		view(rotated, j:n) .+= t .* view(X, j:n, j)
		X[j, j] = diagonal
	end
	slope = rotated[2] / X[2, 2]
	intercept = (rotated[1] + -slope * X[1, 2]) / X[1, 1]
	(intercept, slope)
end

"""
	SmoothingModel(trend, damped)

An exponential smoothing model with additive errors and no season: the level only (`trend = false`, simple
exponential smoothing), with an additive trend (Holt's linear trend), or with a damped one (`damped = true`).
"""
struct SmoothingModel
	trend::Bool
	damped::Bool
end

"""
	starting_parameters(model, y)

The parameters `ets` of forecast 8.2 starts its optimiser from: the smoothing parameters of `initparam` (alpha, then
beta and phi as the model has them), then the initial states of `initstate`: the mean of the first ten values (the
level), or the least squares line through them (its intercept the level, its slope the trend).
"""
function starting_parameters(model::SmoothingModel, y)
	alpha = max(LOWER.alpha + 0.5 * (UPPER.alpha - LOWER.alpha), LOWER.beta + 2e-3)
	(alpha > 1 || alpha < 0) && (alpha = LOWER.alpha + 2e-3)
	parameters = [alpha]
	if model.trend
		upper = min(UPPER.beta, alpha)
		beta = LOWER.beta + 0.1 * (upper - LOWER.beta)
		(beta < 0 || beta > alpha) && (beta = alpha - 1e-3)
		push!(parameters, beta)
	end
	if model.damped
		phi = LOWER.phi + 0.99 * (UPPER.phi - LOWER.phi)
		(phi < 0 || phi > 1) && (phi = UPPER.phi - 1e-3)
		push!(parameters, phi)
	end
	first = min(10, length(y))
	if model.trend
		level, slope = least_squares(1:first, view(y, 1:first))
		if abs(level + slope) < 1e-8
			level, slope = level * (1 + 1e-3), slope * (1 - 1e-3)
		end
		append!(parameters, (level, slope))
	else
		push!(parameters, r_mean(view(y, 1:first)))
	end
	parameters
end

"""The smoothing parameters and the initial states in `parameters`, in the order of `starting_parameters`."""
function unpack(model::SmoothingModel, parameters)
	alpha = parameters[1]
	beta = model.trend ? parameters[2] : 0.0
	phi = model.damped ? parameters[3] : 1.0
	level = parameters[end - model.trend]
	slope = model.trend ? parameters[end] : 0.0
	(; alpha, beta, phi, level, slope)
end

"""Whether the smoothing parameters are within the bounds "both" of `ets`: the usual ones and the admissible ones."""
function admissible(model::SmoothingModel, alpha, beta, phi)
	(alpha < LOWER.alpha || alpha > UPPER.alpha) && return false
	model.trend && (beta < LOWER.beta || beta > alpha || beta > UPPER.beta) && return false
	model.damped && (phi < LOWER.phi || phi > UPPER.phi) && return false
	(phi < 0 || phi > 1 + 1e-8) && return false
	(alpha < 1 - 1 / phi || alpha > 1 + 1 / phi) && return false
	model.trend && (beta < alpha * (phi - 1) || beta > (1 + phi) * (2 - alpha)) && return false
	true
end

"""
	smooth(model, y, alpha, beta, phi, level, slope)

The recursions of `etscalc.c` over the values of `y`: the mean squared one-step error, as the C code averages it, and
the level and the trend after the last value.
"""
function smooth(model::SmoothingModel, y, alpha, beta, phi, level, slope)
	mse, count = 0.0, 0.0
	for value in y
		forecast = model.trend ? level + phi * slope : level
		abs(forecast - NA) < 1e-10 && return (; mse, level, slope)
		count += 1.0
		error = value - forecast
		mse = (mse * (count - 1.0) + error * error) / count
		damped_slope = model.trend ? phi * slope : 0.0
		previous = level
		level = forecast + alpha * (value - forecast)
		if model.trend
			slope = damped_slope + (beta / alpha) * ((level - previous) - damped_slope)
		end
	end
	(; mse, level, slope)
end

"""
The objective `ets` minimises for the criterion "mse": the mean squared one-step error of `parameters`, or infinity
when its smoothing parameters are out of bounds.
"""
function objective(model::SmoothingModel, y, parameters)
	p = unpack(model, parameters)
	admissible(model, p.alpha, p.beta, p.phi) || return Inf
	smooth(model, y, p.alpha, p.beta, p.phi, p.level, p.slope).mse
end

"""
	nelder_mead(f, start; maxit = MAXIT)

The minimum of `f` by R's Nelder-Mead (`nmmin` of `optim.c`), as `ets` calls it: no absolute tolerance, a relative
tolerance of the square root of the machine epsilon, the coefficients 1 (reflection), 0.5 (contraction) and 2
(expansion), and at most `maxit` evaluations. A value of `f` that is not finite counts as 1e35.
"""
function nelder_mead(f, start::Vector{Float64}; maxit = MAXIT)
	n = length(start)
	reflection, contraction, expansion = 1.0, 0.5, 2.0
	abstol, intol = -Inf, sqrt(eps(Float64))
	point = copy(start)
	value = f(point)
	isfinite(value) || throw(ArgumentError("the objective cannot be computed at the starting parameters"))
	funcount = 1
	convtol = intol * (abs(value) + intol)
	n1 = n + 1
	C = n + 2
	# P[i, j]: coordinate i (row n1 the value of f) of vertex j; column C holds the centroid
	P = zeros(n1, C)
	P[n1, 1] = value
	P[1:n, 1] .= point
	L = 1
	size = 0.0
	step = 0.0
	for i in 1:n
		0.1 * abs(point[i]) > step && (step = 0.1 * abs(point[i]))
	end
	step == 0.0 && (step = 0.1)
	for j in 2:n1
		P[1:n, j] .= point
		trystep = step
		while P[j - 1, j] == point[j - 1]
			P[j - 1, j] = point[j - 1] + trystep
			trystep *= 10
		end
		size += trystep
	end
	oldsize = size
	calcvert = true
	finite(v) = isfinite(v) ? v : BIG
	while true
		if calcvert
			for j in 1:n1
				if j != L
					point .= view(P, 1:n, j)
					P[n1, j] = finite(f(point))
					funcount += 1
				end
			end
			calcvert = false
		end
		VL = P[n1, L]
		VH = VL
		H = L
		for j in 1:n1
			if j != L
				v = P[n1, j]
				if v < VL
					L = j
					VL = v
				end
				if v > VH
					H = j
					VH = v
				end
			end
		end
		(VH <= VL + convtol || VL <= abstol) && break
		for i in 1:n
			temp = -P[i, H]
			for j in 1:n1
				temp += P[i, j]
			end
			P[i, C] = temp / n
		end
		for i in 1:n
			point[i] = (1.0 + reflection) * P[i, C] - reflection * P[i, H]
		end
		VR = finite(f(point))
		funcount += 1
		if VR < VL
			P[n1, C] = VR
			for i in 1:n
				v = expansion * point[i] + (1 - expansion) * P[i, C]
				P[i, C] = point[i]
				point[i] = v
			end
			v = finite(f(point))
			funcount += 1
			if v < VR
				P[1:n, H] .= point
				P[n1, H] = v
			else
				P[1:n, H] .= view(P, 1:n, C)
				P[n1, H] = VR
			end
		else
			if VR < VH
				P[1:n, H] .= point
				P[n1, H] = VR
			end
			for i in 1:n
				point[i] = (1 - contraction) * P[i, H] + contraction * P[i, C]
			end
			v = finite(f(point))
			funcount += 1
			if v < P[n1, H]
				P[1:n, H] .= point
				P[n1, H] = v
			elseif VR >= VH
				calcvert = true
				size = 0.0
				for j in 1:n1
					if j != L
						for i in 1:n
							P[i, j] = contraction * (P[i, j] - P[i, L]) + P[i, L]
							size += abs(P[i, j] - P[i, L])
						end
					end
				end
				size < oldsize || break
				oldsize = size
			end
		end
		funcount <= maxit || break
	end
	P[1:n, L]
end

"""
	fit(model, y)

The smoothing parameters and the states of `model` fitted to the values of `y` as `ets` of forecast 8.2 fits them:
alpha, beta, phi, and the level and the trend after the last value.
"""
function fit(model::SmoothingModel, y::AbstractVector{Float64})
	parameters = starting_parameters(model, y)
	needed = 2 + 2 * model.trend + model.damped
	length(y) > needed + 4 || throw(ArgumentError("$(length(y)) values are too few: this model needs at least $(needed + 5), as ets of R's forecast optimises it."))
	fitted = nelder_mead(p -> objective(model, y, p), parameters)
	p = unpack(model, fitted)
	last = smooth(model, y, p.alpha, p.beta, p.phi, p.level, p.slope)
	(; p.alpha, p.beta, p.phi, last.level, last.slope)
end

"""
The forecasts over `horizon` steps from the level and the trend of `fitted`, as `forecast.ets` computes them (its
`class1`): the level, plus the trend damped by phi at each step.
"""
function point_forecasts(model::SmoothingModel, fitted, horizon)
	model.trend || return fill(fitted.level, horizon)
	phi = model.damped ? fitted.phi : 1.0
	# The powers of the transition matrix [1 phi; 0 phi], as class1 multiplies them: F12 and F22 of each
	f12, f22 = 0.0, 1.0
	forecasts = Vector{Float64}(undef, horizon)
	for step in 1:horizon
		forecasts[step] = fitted.level + (f12 + phi * f22) * fitted.slope
		f12, f22 = phi + f12 * phi, f22 * phi
	end
	forecasts
end

"""
	ses(y, horizon)

The forecasts over `horizon` steps of simple exponential smoothing of the values of `y`, fitted as `ses` of R's
forecast 8.2 fits it: `ets` with the model ANN, on the mean squared one-step error.
"""
function ses(y::AbstractVector{<:Real}, horizon::Integer)
	model = SmoothingModel(false, false)
	point_forecasts(model, fit(model, Float64.(y)), horizon)
end

"""
	holt(y, horizon; damped = false)

The forecasts over `horizon` steps of Holt's linear trend method of the values of `y`, damped or not, fitted as `holt`
of R's forecast 8.2 fits it: `ets` with the model AAN, on the mean squared one-step error.
"""
function holt(y::AbstractVector{<:Real}, horizon::Integer; damped::Bool = false)
	model = SmoothingModel(true, damped)
	point_forecasts(model, fit(model, Float64.(y)), horizon)
end
