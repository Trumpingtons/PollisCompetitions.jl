"""Where Pollis keeps the data of datasets that are not built in, a folder each, on this computer."""
const HOME = joinpath(homedir(), ".pollis", "competitions")

"""
The names and formats of the M competitions and Tourism, whose `info.toml` does not give them: "monash" for series
scored by sMAPE, MASE and OWA, as M1 and M3 are, and "m4", "m5" and "m6" for those competitions, with their entries.
"""
const KNOWN_DATA = Dict("m1" => ("M1", "monash"), "m3" => ("M3", "monash"), "tourism" => ("Tourism", "monash"),
	"m4" => ("M4", "m4"), "m5" => ("M5", "m5"), "m6" => ("M6", "m6"))

"""
	is_dataset(path)

Whether `path` is the folder of a dataset of your own: an absolute path holding `series.parquet` and
`observations.parquet`, with the columns of `series` and `observations`, as Pollis writes them when a dataset is added
in Compose > Prediction Competitions > Manage Competition Datasets. Every function that takes the id of a dataset takes
such a folder in its place, and `score` scores it as M1 and M3 are scored: sMAPE, MASE and OWA, against Naive2
computed on this computer.
"""
is_dataset(path) = path isa AbstractString && isabspath(path) && isfile(joinpath(path, "series.parquet")) && isfile(joinpath(path, "observations.parquet"))

"""
The folder of the data of dataset `id` on this computer: the folder `id` itself for a dataset of your own, else its
folder in `data/builtin` when it is built in, else its folder in `HOME`.
"""
function folder(id)
	is_dataset(id) && return id
	builtin = joinpath(BUILTIN, id)
	isdir(builtin) ? builtin : joinpath(HOME, id)
end

"""
	info(id)

What is on this computer of dataset `id`, from the `info.toml` of its folder: its name and format when it gives them,
the number of rows of each of its tables, and, for each entry whose forecasts are there (by its number), the number of
series it forecast over their whole horizon. `nothing` when its data are not on this computer. For the folder of a
dataset of your own (`is_dataset`), the folder.
"""
function info(id)
	is_dataset(id) && return Dict{String, Any}("folder" => id)
	path = joinpath(folder(id), "info.toml")
	isfile(path) ? TOML.parsefile(path) : nothing
end

"""
The entry of a dataset of your own in the folder `path`: its id, the folder, its name, from the `[[datasets]]` table of
the `dataset.toml` Pollis writes beside its files or else the folder's, and its format, that of M1 and M3.
"""
function dataset_entry(path)
	toml = joinpath(path, "dataset.toml")
	datasets = isfile(toml) ? get(TOML.parsefile(toml), "datasets", []) : []
	name = isempty(datasets) ? basename(normpath(path)) : get(first(datasets), "dataset_name", basename(normpath(path)))
	Dict("id" => path, "name" => name, "format" => "monash")
end

"""
	competition(id)

The dataset `id` whose data are on this computer, as the functions that read and score it need it: its id, its name
and its format. For the folder of a dataset of your own (`is_dataset`), its name and format. An error when its data
are not on this computer.
"""
function competition(id)
	is_dataset(id) && return dataset_entry(id)
	current = info(id)
	current === nothing && error("The data of $(id) are not on this computer: there is no $(joinpath(folder(id), "info.toml")).")
	name, format = get(KNOWN_DATA, id, (id, "monash"))
	Dict("id" => id, "name" => get(current, "name", name), "format" => get(current, "format", format))
end

"""
	entry_number(id, entry; known = entries(id))

The number of an entry of dataset `id`, given by its number or its name. A name that two entries share (in M5, an entry
of Accuracy and one of Uncertainty) is an error that names both numbers.
"""
function entry_number(id, entry; known = entries(id))
	if entry isa Integer
		entry in known.entry || error("$(competition(id)["name"]) has no entry $(entry).")
		return Int(entry)
	end
	found = [number for (number, name) in zip(known.entry, known.name) if name == string(entry)]
	isempty(found) && error("$(competition(id)["name"]) has no entry named $(entry).")
	length(found) == 1 || error("$(competition(id)["name"]) has $(length(found)) entries named $(entry): give its number, one of $(join(found, ", ")).")
	Int(only(found))
end
