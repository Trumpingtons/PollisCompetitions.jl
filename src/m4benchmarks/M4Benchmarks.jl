"""
	M4Benchmarks

The eight statistical benchmarks of the M4 forecasting competition (Naive, sNaive, Naive2, SES, Holt, Damped, Theta
and Com), computed as its organisers computed them in `Benchmarks and Evaluation.R`, with simple exponential smoothing
and Holt's method fitted as R's forecast 8.2 fits them. On the series of M4 they give the published forecasts of the
benchmarks.

```julia
import PollisCompetitions.M4Benchmarks as MB
y = [5172.1, 5133.5, 5186.9, 5084.6, 5182.0, 5414.3, 5576.2, 5752.9, 5955.2, 6087.8, 6238.9, 6262.9]
forecasts = MB.benchmarks(y; period = 1, horizon = 6)
```
"""
module M4Benchmarks

export BENCHMARKS, benchmarks, holt, is_seasonal, seasonal_index, ses, theta

include("ets.jl")
include("benchmarks.jl")

end
