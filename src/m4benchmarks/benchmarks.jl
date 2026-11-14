# The benchmarks of M4 as `Benchmarks and Evaluation.R` of its organisers computes them (Mcompetitions/M4-methods).

"""
The eight statistical benchmarks of M4, by the names the organisers gave their entries: Naive, Seasonal Naive (sNaive),
Naive2, Simple Exponential Smoothing (SES), Holt, Damped, Theta, and Com, the mean of SES, Holt and Damped.
"""
const BENCHMARKS = (:Naive, :sNaive, :Naive2, :SES, :Holt, :Damped, :Theta, :Com)

"""
	is_seasonal(y, period)

Whether the series `y` is seasonal by the test of M4 (`SeasonalityTest`): at least three periods of values, and an
autocorrelation at the lag `period` above its 90% limit, 1.645 standard errors computed from the autocorrelations at
the lags before it. R's `acf` reaches as far as the lag `10 log10(n)`, so that a longer period is never seasonal.
"""
function is_seasonal(y::AbstractVector{<:Real}, period::Integer)
	n = length(y)
	period > 1 || return false
	n < 3 * period && return false
	period > min(floor(Int, 10 * log10(n)), n - 1) && return false
	total = 0.0
	for value in y
		total += value
	end
	mean = total / n
	x = [value - mean for value in y]
	function covariance(lag)
		sum = 0.0
		for i in 1:(n - lag)
			sum += x[i + lag] * x[i]
		end
		sum / n
	end
	scale = sqrt(covariance(0))
	correlation(lag) = clamp(covariance(lag) / (scale * scale), -1.0, 1.0)
	cumulative = 1.0
	for lag in 1:(period - 1)
		cumulative += 2 * correlation(lag)^2
	end
	abs(correlation(period)) > 1.645 / sqrt(n) * sqrt(cumulative)
end

"""
	seasonal_index(y, period)

The seasonal index of the series `y`, one for each of its values, by the classical multiplicative decomposition (R's
`decompose`): the ratios of the values to a centred moving average over one period, averaged at each position of the
period and scaled to a mean of 1.
"""
function seasonal_index(y::AbstractVector{<:Real}, period::Integer)
	n = length(y)
	n >= 2 * period || throw(ArgumentError("$(n) values are too few to decompose: at least two periods ($(2 * period)) are needed."))
	weights = iseven(period) ? [0.5; ones(period - 1); 0.5] ./ period : ones(period) ./ period
	width = length(weights)
	shift = width ÷ 2
	ratios = fill(NaN, n)
	for i in 0:(n - 1)
		(i + shift - (width - 1) < 0 || i + shift >= n) && continue
		trend = 0.0
		for j in 0:(width - 1)
			trend += weights[j + 1] * y[i + shift - j + 1]
		end
		ratios[i + 1] = y[i + 1] / trend
	end
	figure = [r_mean(filter(!isnan, ratios[position:period:n])) for position in 1:period]
	figure = figure ./ r_mean(figure)
	[figure[mod1(t, period)] for t in 1:n]
end

"""
	theta(y, horizon)

The forecasts over `horizon` steps of the Theta method as M4 computes it (`Theta.classic`): the mean of the least
squares line of `y` on time (the theta line 0) and of simple exponential smoothing of the theta line 2, twice `y` less
that line; a negative forecast becomes 0.
"""
function theta(y::AbstractVector{<:Real}, horizon::Integer)
	y = Float64.(y)
	n = length(y)
	intercept, slope = least_squares(1:n, y)
	line = [intercept + slope * t for t in 1:n]
	smoothed = ses(2 .* y .+ (1 - 2) .* line, horizon)
	ahead = [intercept + slope * t for t in (n + 1):(n + horizon)]
	[max(value, 0.0) for value in smoothed .* 0.5 .+ ahead .* 0.5]
end

"""
	benchmarks(y; period, horizon)

The forecasts of the eight benchmarks of M4 (`BENCHMARKS`) for the series `y`, its values in order, whose seasonal
period is `period` (1 for none), over `horizon` steps: a NamedTuple of a vector of forecasts for each.

Naive repeats the last value, and sNaive the last period of values. A series that passes the seasonality test of M4
(`is_seasonal`) is adjusted by its seasonal index (`seasonal_index`); Naive2, SES, Holt, Damped and Theta forecast the
adjusted values, and their forecasts are multiplied by the last period of the index. SES, Holt and Damped are fitted as
R's forecast 8.2 fits them, and Com is their mean.

```julia
import PollisCompetitions.M4Benchmarks: benchmarks
y = [5172.1, 5133.5, 5186.9, 5084.6, 5182.0, 5414.3, 5576.2, 5752.9, 5955.2, 6087.8, 6238.9, 6262.9]
forecasts = benchmarks(y; period = 1, horizon = 6)
forecasts.Theta
```
"""
function benchmarks(y::AbstractVector{<:Real}; period::Integer, horizon::Integer)
	period >= 1 || throw(ArgumentError("the period must be at least 1, not $(period)"))
	horizon >= 1 || throw(ArgumentError("the horizon must be at least 1, not $(horizon)"))
	y = Float64.(y)
	n = length(y)
	if is_seasonal(y, period)
		index = seasonal_index(y, period)
		adjusted = y ./ index
		ahead = [index[n - period + 1 + mod(step - 1, period)] for step in 1:horizon]
	else
		adjusted, ahead = y, ones(horizon)
	end
	naive = fill(y[n], horizon)
	seasonal_naive = period > 1 ? [y[n - period + 1 + mod(step - 1, period)] for step in 1:horizon] : naive
	smoothed = ses(adjusted, horizon) .* ahead
	trend = holt(adjusted, horizon) .* ahead
	damped = holt(adjusted, horizon; damped = true) .* ahead
	(; Naive = naive, sNaive = seasonal_naive, Naive2 = fill(adjusted[n], horizon) .* ahead, SES = smoothed,
		Holt = trend, Damped = damped, Theta = theta(adjusted, horizon) .* ahead, Com = (smoothed .+ trend .+ damped) ./ 3)
end
