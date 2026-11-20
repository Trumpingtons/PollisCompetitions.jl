"""
	Benchmarks

Eight statistical benchmarks of forecasting (Naive, sNaive, Naive2, SES, Holt, Damped, Theta and Com): a series that
passes a seasonality test is adjusted by its classical multiplicative seasonal index, and simple exponential smoothing
and Holt's method are fitted as R's forecast 8.2 fits them.

```julia
import PollisCompetitions.Benchmarks as B
y = [5172.1, 5133.5, 5186.9, 5084.6, 5182.0, 5414.3, 5576.2, 5752.9, 5955.2, 6087.8, 6238.9, 6262.9]
forecasts = B.benchmarks(y; period = 1, horizon = 6)
```
"""
module Benchmarks

export BENCHMARKS, benchmarks, holt, is_seasonal, seasonal_index, ses, theta

include("ets.jl")
include("methods.jl")

end
