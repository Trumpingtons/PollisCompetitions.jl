"""Where Pollis keeps the data of datasets that are not built in, a folder each, on this computer."""
const HOME = joinpath(homedir(), ".pollis", "competitions")

"""
	is_dataset(path)

Whether `path` is the folder of a dataset of your own: an absolute path holding `series.parquet` and
`observations.parquet`, with the columns of `series` and `observations`, as Pollis writes them when a dataset is added
in Compose > Prediction Competitions > Manage Competition Datasets. Every function that takes the id of a dataset takes
such a folder in its place, and `score` scores it as every forecasting dataset: sMAPE, MASE and OWA, against Naive2
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

What is on this computer of dataset `id`, from the `info.toml` of its folder: its name and format, and the number of
rows of each of its tables. `nothing` when its data are not on this computer. For the folder of a dataset of your own
(`is_dataset`), the folder.
"""
function info(id)
	is_dataset(id) && return Dict{String, Any}("folder" => id)
	path = joinpath(folder(id), "info.toml")
	isfile(path) ? TOML.parsefile(path) : nothing
end

"""
The entry of a dataset of your own in the folder `path`: its id, the folder, its name, from the `[[datasets]]` table of
the `dataset.toml` Pollis writes beside its files or else the folder's, and its format, that of a forecasting dataset.
"""
function dataset_entry(path)
	toml = joinpath(path, "dataset.toml")
	datasets = isfile(toml) ? get(TOML.parsefile(toml), "datasets", []) : []
	name = isempty(datasets) ? basename(normpath(path)) : get(first(datasets), "dataset_name", basename(normpath(path)))
	Dict("id" => path, "name" => name, "format" => "monash")
end

"""
	competition(id)

The dataset `id` whose data are on this computer, as the functions that read and score it need it: its id, and the
name and format its `info.toml` gives, the name of the Dataset Catalog when it gives none. For the folder of a dataset
of your own (`is_dataset`), its name and format. An error when its data are not on this computer, or its `info.toml`
gives no format.
"""
function competition(id)
	is_dataset(id) && return dataset_entry(id)
	current = info(id)
	current === nothing && error("The data of $(id) are not on this computer: there is no $(joinpath(folder(id), "info.toml")).")
	haskey(current, "format") || error("The info.toml of $(id) gives no format: its reader writes it, with its name.")
	name = get(current, "name", nothing)
	if name === nothing
		datasets = metadata_entries(METADATA, "datasets.toml", "datasets")
		entry = findfirst(entry -> entry["dataset_id"] == id, datasets)
		name = entry === nothing ? id : datasets[entry]["dataset_name"]
	end
	Dict("id" => id, "name" => name, "format" => current["format"])
end
