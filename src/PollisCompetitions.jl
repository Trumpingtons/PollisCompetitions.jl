"""
	PollisCompetitions

The data of published forecasting competitions, as their organisers gave them: the series, split into the part the
forecasters saw (`train`) and the part their forecasts were scored on (`test`), and, where they are published, the
entries, their forecasts and their scores. Pollis keeps them on this computer as Parquet files, which Julia reads
through DuckDB, filtered first, so that a whole competition is never in memory.

```julia
import PollisCompetitions as PC
PC.competitions()                                   # the competitions of the catalogue
PC.download("m4")                                   # the series, the entries and the published scores
PC.download_forecasts("m4"; entries = ["118", "Theta"])
series = PC.series("m4"; frequency = "Yearly")
observations = PC.observations("m4"; series = 1)
forecasts = PC.forecasts("m4"; entry = "118", frequency = "Yearly")
```

Every competition is downloaded from its source, at the revision of the catalogue, each file checked against its
SHA-256, then converted on this computer into `HOME/<competition>`.
"""
module PollisCompetitions

import DBInterface
import Downloads
import DuckDB
import TOML
import Tables
using Dates: now, UTC
using LibArchive_jll: bsdtar
using SHA: sha256

"""Where Pollis keeps the competitions on this computer."""
const HOME = joinpath(homedir(), ".pollis", "competitions")

include("catalogue.jl")
include("fetch.jl")
include("parquet.jl")
include("monash.jl")
include("m4.jl")
include("download.jl")
include("tables.jl")

end
