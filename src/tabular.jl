"""
The measure that scores the predictions of a tabular dataset, by its Response Type in the Dataset Catalog, as TabArena
scores its datasets: rmse for Continuous and Count, roc_auc for Binary, log_loss for Multiclass. Ordered has none yet.
"""
const TABULAR_MEASURES = Dict("Continuous" => "rmse", "Count" => "rmse", "Binary" => "roc_auc", "Multiclass" => "log_loss")

"""
	rmse(truth, prediction)

The root mean squared error of the predictions of a numeric target: the square root of the mean of the squared
differences between `truth` and `prediction`.
"""
function rmse(truth::AbstractVector{<:Real}, prediction::AbstractVector{<:Real})
	length(truth) == length(prediction) || error("$(length(prediction)) predictions for $(length(truth)) rows.")
	sqrt(sum(abs2, Float64.(truth) .- Float64.(prediction)) / length(truth))
end

"""
	roc_auc(truth, score)

The area under the ROC curve of the scores of a binary target, `truth` being true for the rows of the second class:
the share of the pairs of a row of the second class and a row of the first in which the row of the second class has
the higher score, a tie counting one half. It is computed from the ranks of the scores, tied scores taking the mean of
their ranks. An error when the rows are all of one class, or a score is NaN.
"""
function roc_auc(truth::AbstractVector{Bool}, score::AbstractVector{<:Real})
	n = length(truth)
	n == length(score) || error("$(length(score)) scores for $(n) rows.")
	any(isnan, score) && error("A score is NaN.")
	positives = count(truth)
	negatives = n - positives
	(positives == 0 || negatives == 0) && error("The area under the ROC curve needs rows of both classes.")
	order = sortperm(score)
	ranks = Vector{Float64}(undef, n)
	low = 1
	while low <= n
		high = low
		while high < n && score[order[high + 1]] == score[order[low]]
			high += 1
		end
		ranks[order[low:high]] .= (low + high) / 2
		low = high + 1
	end
	(sum(ranks[truth]) - positives * (positives + 1) / 2) / (positives * negatives)
end

"""
	log_loss(truth, probabilities)

The mean negative log-likelihood of the predictions of a multiclass target: `truth` gives the class of each row, as
its column in `probabilities` (1 to K), and `probabilities` has a row per row of `truth` and a column per class. The
probability of each row's class is first clipped to [ε, 1 - ε], ε being the machine epsilon of Float64, as
scikit-learn's log_loss clips it, so that a probability of 0 gives a finite loss.
"""
function log_loss(truth::AbstractVector{<:Integer}, probabilities::AbstractMatrix{<:Real})
	size(probabilities, 1) == length(truth) || error("$(size(probabilities, 1)) rows of probabilities for $(length(truth)) rows.")
	all(c -> 1 <= c <= size(probabilities, 2), truth) || error("A class is not a column of the probabilities.")
	ε = eps(Float64)
	-sum(log(clamp(Float64(probabilities[r, truth[r]]), ε, 1 - ε)) for r in eachindex(truth)) / length(truth)
end
