"""The catalogue of the competitions, `data/catalogue.toml`."""
const CATALOGUE_FILE = joinpath(dirname(@__DIR__), "data", "catalogue.toml")

"""The entries of the catalogue, one a competition, as TOML gives them."""
catalogue() = TOML.parsefile(CATALOGUE_FILE)["competitions"]

"""
	competition(id)

The entry of the catalogue of competition `id`, such as "m4": its name, year, source, revision, licence, papers,
measures and files.
"""
function competition(id)
	for entry in catalogue()
		entry["id"] == id && return entry
	end
	error("No competition \"$(id)\" in the catalogue: one of $(join([entry["id"] for entry in catalogue()], ", ")).")
end

"""The facts of the catalogue that `competitions()` gives for each competition."""
const CATALOGUE_COLUMNS = ("id", "name", "year", "series", "frequencies", "entries", "availability", "source", "licence", "papers", "measures")

"""
	competitions()

The competitions of the catalogue, as a table: id, name, year, the number of series, the frequencies, the number of
entries published (0 when none are), the availability (Download, or Built In), the source, its licence, the papers
(keys of PollisReferences) and the measures of the organisers. `downloaded` says whether the competition is on this
computer.
"""
function competitions()
	entries = catalogue()
	columns = Dict{String, Vector}(name => [get(entry, name, missing) for entry in entries] for name in CATALOGUE_COLUMNS)
	columns["entries"] = [get(entry, "entries", 0) for entry in entries]
	(; (Symbol(name) => columns[name] for name in CATALOGUE_COLUMNS)..., downloaded = [isfile(info_file(entry["id"])) for entry in entries])
end

"""The files of the catalogue of competition `id` that play `role` ("series", "train", "forecasts" and so on)."""
files_of(id, role) = [file for file in competition(id)["files"] if file["role"] == role]
