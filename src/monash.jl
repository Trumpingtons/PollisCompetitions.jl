"""
	read_tsf(path)

A file of the Monash Time Series Forecasting Archive (.tsf), as `(; frequency, horizon, rows)`: the frequency and the
horizon of its header (`nothing` when it has none), and each series, `(; name, start, values)`, its start `nothing`
when the file gives none. The attributes of the header say what comes before the values of a series, separated by
colons. A missing value, `?`, is an error: the competitions of the catalogue have none.
"""
function read_tsf(path)
	attributes = String[]
	frequency = horizon = nothing
	rows = @NamedTuple{name::String, start::Union{Nothing, String}, values::Vector{Float64}}[]
	in_data = false
	# The comments of the header are in Latin-1, which these lines never read
	for line in eachline(path)
		line = strip(line)
		(isempty(line) || startswith(line, '#')) && continue
		if !in_data
			words = split(line)
			keyword = lowercase(first(words))
			if keyword == "@attribute"
				push!(attributes, words[2])
			elseif keyword == "@frequency"
				frequency = String(words[2])
			elseif keyword == "@horizon"
				horizon = parse(Int, words[2])
			elseif keyword == "@data"
				in_data = true
			end
			continue
		end
		fields = split(line, ':'; limit = length(attributes) + 1)
		length(fields) == length(attributes) + 1 || error("$(basename(path)): a series has $(length(fields) - 1) attributes, not $(length(attributes)).")
		values = [value == "?" ? error("$(basename(path)): series $(fields[1]) has a missing value.") : parse(Float64, value) for value in split(fields[end], ',')]
		start = "start_timestamp" in attributes ? String(fields[findfirst(==("start_timestamp"), attributes)]) : nothing
		push!(rows, (; name = String(fields[1]), start, values))
	end
	in_data || error("$(basename(path)) has no @data line.")
	(; frequency, horizon, rows)
end
