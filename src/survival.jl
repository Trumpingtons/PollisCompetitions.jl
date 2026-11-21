# The measures of the Low-Dimensional Survival Benchmark (Burk, Zobolas, Bischl, Bender, Wright and Sonabend, 2026), as
# the benchmark computes them: mlr3proba 0.7.4 (commit 5cc5c42) with the settings of its R_helpers.R, and the step
# functions of distr6 1.8.4 that read a survival curve at a time. Each function follows the R or C++ it is ported from,
# named in its docstring, including what those do at the edges, so that its values are those the benchmark published.

"""The measures of a survival dataset, in the order the benchmark lists them."""
const SURVIVAL_MEASURES = ("harrell_c", "uno_c", "isll", "isll_erv", "isbs", "isbs_erv", "dcalib", "alpha_calib")

"""The share of the test rows no longer at risk past which the integrated scores stop (`p_max` of ISBS and ISLL)."""
const SURVIVAL_P_MAX = 0.8

"""The bound of D-calibration and of alpha-calibration (`truncate`), and the bins of D-calibration (`B`)."""
const SURVIVAL_TRUNCATE = 1000.0
const SURVIVAL_BINS = 10

"""The floor of mlr3proba's scores (`eps`): of a probability in the log loss, of a weight, of a cumulative hazard."""
const SURVIVAL_EPS = 1e-3

"""
	r_time(t)

`t` as R gives it back from the column names of a matrix: written with 15 significant digits and read again. mlr3proba
keeps the times of a predicted survival matrix, and of the scores it integrates, as column names.
"""
r_time(t) = parse(Float64, Printf.@sprintf("%.15g", t))

"""
	survfit(time, event)

The curve of R's `survival::survfit(Surv(time, event) ~ 1)`: its times, every distinct time of the rows, events and
censorings, in increasing order; the number at risk just before each; the Kaplan-Meier survival; and the Nelson-Aalen
cumulative hazard. Times closer than survfit's tolerance are first made one, as its `timefix` does (`time_fix`).
"""
function survfit(time::AbstractVector{<:Real}, event::AbstractVector{<:Integer})
	fixed = time_fix(Float64.(time))
	order = sortperm(fixed)
	sorted, happened = fixed[order], event[order]
	n = length(sorted)
	times, at_risk, survival, hazard = Float64[], Int[], Float64[], Float64[]
	s, h, k = 1.0, 0.0, 1
	while k <= n
		t, deaths, last = sorted[k], 0, k
		while last <= n && sorted[last] == t
			deaths += happened[last] == 1
			last += 1
		end
		risk = n - k + 1
		s *= 1 - deaths / risk
		h += deaths / risk
		push!(times, t)
		push!(at_risk, risk)
		push!(survival, s)
		push!(hazard, h)
		k = last
	end
	(; times, at_risk, survival, hazard, n)
end

"""
	time_fix(time)

The times as survival 3.8-3's `aeqSurv` leaves them, which `survfit` applies by default: of the distinct times in
increasing order, one whose gap from the one before is at most sqrt(eps) (about 1.5e-8), or at most sqrt(eps) times the
mean of the distinct times, is tied with it, and each time becomes the first time of its run of ties.
"""
function time_fix(time::Vector{Float64})
	y = sort(unique(filter(isfinite, time)))
	length(y) < 2 && return time
	tolerance = sqrt(eps(Float64))
	scale = sum(abs, y) / length(y)
	tied = [(d = y[k + 1] - y[k]; d <= tolerance || d / scale <= tolerance) for k in 1:length(y) - 1]
	any(tied) || return time
	cuts = y[[true; .!tied]]
	[isfinite(t) ? cuts[searchsortedlast(cuts, t)] : t for t in time]
end

"""
	step_index(times, t)

The column of a curve given at `times` (increasing) that holds its value at `t`, the last time not after `t`; 0 when
`t` comes before the first, as distr6's `C_Vec_WeightedDiscreteCdf` reads a step function.
"""
step_index(times, t) = searchsortedlast(times, t)

"""
	mortality(times, survival)

The ranking of each test row by risk that mlr3proba gives a prediction made only of survival curves (`crank`, its
`get_mortality`): the sum over the curve's times of -log S(t), an infinite term counted as 0.
"""
mortality(survival::AbstractMatrix) = [sum(s -> (h = -log(s); isinf(h) ? 0.0 : h), row) for row in eachrow(survival)]

"""
	concordance(time, event, crank, weight; train_time, train_event)

Harrell's C (`weight = :I`) or Uno's C (`weight = :G2`, the censoring curve of the training rows to the power -2), as
mlr3proba's `cindex` and `c_concordance` compute them, with ties in `crank` counted as half, no time cut-off, and the
result in single precision, as `c_concordance` returns it. 0.5 when every row has the same `crank`.
"""
function concordance(time, event, crank, weight::Symbol; train_time = nothing, train_event = nothing)
	length(unique(crank)) == 1 && return 0.5
	order = sortperm(time)
	t, e, c = Float64.(time[order]), event[order], crank[order]
	t_max = maximum(t) + 1
	censoring = weight === :I ? nothing : survfit(train_time, 1 .- train_event)
	cens_surv = censoring === nothing ? Float64[] : [s == 0 ? SURVIVAL_EPS : s for s in censoring.survival]
	numerator, denominator = 0.0, 0.0
	for i in 1:length(t) - 1
		e[i] == 1 || continue
		w = -1.0
		for j in i + 1:length(t)
			if t[i] < t[j] && t[i] < t_max
				if w == -1
					if weight === :I
						w = 1.0
					else
						l = step_index(censoring.times, t[i])
						l > 0 && (w = cens_surv[l]^-2)
					end
				end
				denominator += w
				if c[i] > c[j]
					numerator += w
				elseif c[i] == c[j]
					numerator += 0.5 * w
				end
			end
		end
	end
	denominator == 0 && error("No events, or all survival times are identical: the concordance cannot be computed.")
	Float64(Float32(numerator / denominator))
end

"""
	integrated_score(loss, test_time, test_event, times, survival; train_time, train_event)

The integrated survival Brier score (`loss = :graf`) or log loss (`loss = :intslogloss`), as mlr3proba's
`weighted_survival_score` and `integrated_score` compute them with `p_max = 0.8`, `proper = FALSE`, `eps = 1e-3` and
method 2: at the distinct test times up to the time past which more than 80% of the test rows are no longer at risk,
each row's loss weighted by the inverse of the censoring curve of the training rows, the mean over the rows at each
time (infinite and undefined values left out), integrated over time by the trapezoid rule and divided by the time
spanned.
"""
function integrated_score(loss::Symbol, test_time, test_event, times, survival::AbstractMatrix; train_time, train_event)
	tested = survfit(test_time, test_event)
	beyond = findfirst(k -> 1 - tested.at_risk[k] / tested.n > SURVIVAL_P_MAX, eachindex(tested.times))
	t_max = beyond === nothing ? tested.times[end] : tested.times[beyond]
	# The times scored are the distinct test times as they are; only t_max comes from survfit, whose times are fixed
	unique_times = filter(<=(t_max), sort(unique(Float64.(test_time))))
	predicted = r_time.(times)
	columns = step_index.(Ref(predicted), unique_times)
	censoring = survfit(train_time, 1 .- train_event)
	n, m = length(test_time), length(unique_times)
	score = Matrix{Float64}(undef, n, m)
	for i in 1:n
		k = 0.0
		for j in 1:m
			cdf = columns[j] == 0 ? 0.0 : 1 - survival[i, columns[j]]
			alive = test_time[i] > unique_times[j]
			raw = loss === :graf ? (alive ? cdf : 1 - cdf)^2 : -log(max(alive ? 1 - cdf : cdf, SURVIVAL_EPS))
			if alive
				l = step_index(censoring.times, unique_times[j])
				score[i, j] = l == 0 ? 0.0 : raw / censoring.survival[l]
			elseif test_event[i] == 0
				score[i, j] = 0.0
			else
				if k == 0
					l = step_index(censoring.times, test_time[i])
					k = l == 0 ? 1.0 : censoring.survival[l] == 0 ? SURVIVAL_EPS : censoring.survival[l]
				end
				score[i, j] = raw / k
			end
		end
	end
	means = [(finite = filter(isfinite, column); isempty(finite) ? NaN : sum(finite) / length(finite)) for column in eachcol(score)]
	m == 1 && return means[1]
	at = r_time.(unique_times)
	sum((at[j + 1] - at[j]) * (means[j] + means[j + 1]) for j in 1:m - 1) / (2 * (maximum(at) - minimum(at)))
end

"""
	survival_at_own_time(test_time, times, survival)

Each test row's predicted survival at its own time, as distr6's step function reads it: 1 minus the distribution
function 1 - S, which is 0 before the first time.
"""
function survival_at_own_time(test_time, times, survival::AbstractMatrix)
	predicted = r_time.(times)
	[(l = step_index(predicted, test_time[i]); 1 - (l == 0 ? 0.0 : 1 - survival[i, l])) for i in eachindex(test_time)]
end

"""
	d_calibration(test_time, test_event, times, survival)

D-calibration as mlr3proba's `surv.dcalib` computes it with 10 bins and `truncate = 1000`: each row's survival at its
own time, floored at 1e-5, puts an event in its bin and spreads a censored row over its bin and those below; the
statistic is 10/n times the sum of the squared differences of the bins from n/10. A censored row in the first bin adds
1/(10 S) to it once more, as R's `seq.int(0)` gives the indices 1 and 0 in mlr3proba's loop.
"""
function d_calibration(test_time, test_event, times, survival::AbstractMatrix)
	B = SURVIVAL_BINS
	s = max.(survival_at_own_time(test_time, times, survival), 1e-5)
	bins = zeros(B)
	for i in eachindex(s)
		j = ceil(Int, B * s[i])
		if test_event[i] == 1
			bins[j] += 1
		else
			for k in (j - 1 >= 1 ? (1:j - 1) : (1:1))
				bins[k] += 1 / (B * s[i])
			end
			bins[j] += 1 - (j - 1) / (B * s[i])
		end
	end
	n = length(s)
	min(SURVIVAL_TRUNCATE, (B / n) * sum((bins .- n / B) .^ 2))
end

"""
	alpha_calibration(test_time, test_event, times, survival)

Van Houwelingen's alpha as mlr3proba's `surv.calib_alpha` computes it with `method = "ratio"` and `truncate = 1000`: the
number of events divided by the sum of each row's cumulative hazard -log S at its own time, a hazard of 0 or infinity
counted as 1e-3.
"""
function alpha_calibration(test_time, test_event, times, survival::AbstractMatrix)
	hazard = [(h = -log(s); h == Inf || h == 0 ? SURVIVAL_EPS : h) for s in survival_at_own_time(test_time, times, survival)]
	min(SURVIVAL_TRUNCATE, sum(test_event) / sum(hazard))
end

"""
	survival_scores(train_time, train_event, test_time, test_event, times, survival; crank = mortality(survival))

The eight measures of the Low-Dimensional Survival Benchmark of one split, as a Dict by the names of
`SURVIVAL_MEASURES`: Harrell's C and Uno's C of `crank`; the integrated survival log loss and Brier score, and their
explained residual variation (ERV), 1 minus the ratio of the score to that of Kaplan-Meier fitted on the same training
rows; D-calibration; and alpha-calibration. `survival` holds the predicted survival of each test row (a row each) at
`times` (a column each, increasing).
"""
function survival_scores(train_time, train_event, test_time, test_event, times, survival::AbstractMatrix; crank = mortality(survival))
	size(survival) == (length(test_time), length(times)) || error("The survival matrix has $(size(survival, 1)) rows and $(size(survival, 2)) columns, not $(length(test_time)) and $(length(times)).")
	train = (; train_time, train_event)
	# The reference of the ERV: mlr3proba's surv.kaplan, survfit's Kaplan-Meier curve of the training rows for every test row
	curve = survfit(train_time, train_event)
	baseline = repeat(permutedims(curve.survival), length(test_time))
	isll = integrated_score(:intslogloss, test_time, test_event, times, survival; train...)
	isbs = integrated_score(:graf, test_time, test_event, times, survival; train...)
	isll_km = integrated_score(:intslogloss, test_time, test_event, curve.times, baseline; train...)
	isbs_km = integrated_score(:graf, test_time, test_event, curve.times, baseline; train...)
	Dict(
		"harrell_c" => concordance(test_time, test_event, crank, :I),
		"uno_c" => concordance(test_time, test_event, crank, :G2; train...),
		"isll" => isll, "isll_erv" => 1 - isll / isll_km,
		"isbs" => isbs, "isbs_erv" => 1 - isbs / isbs_km,
		"dcalib" => d_calibration(test_time, test_event, times, survival),
		"alpha_calib" => alpha_calibration(test_time, test_event, times, survival),
	)
end
