# PollisCompetitions.jl

The data of the M forecasting competitions, as their organisers gave them, for [Pollis](https://pollis.org): the series, split into the values the forecasters saw and those their forecasts were scored on, and, where they are published, the entries, their forecasts and their scores.

```julia
import PollisCompetitions as PC
PC.competitions()
PC.download("m4")
PC.download_forecasts("m4"; entries = ["118", "Theta"])
yearly = PC.series("m4"; frequency = "Yearly")
values = PC.observations("m4"; series = 1)
forecasts = PC.forecasts("m4"; entry = "118", frequency = "Yearly")
scores = PC.published_scores("m4"; measure = "OWA", breakdown = "frequency")
```

Every function answers a table of columns (a NamedTuple of vectors, which Tables.jl reads).

## Competitions

| Id | Competition | Series | Frequencies | Entries | Source | Licence of the source | |
|---|---|---|---|---|---|---|---|
| `m1` | M1 (1982) | 1,001 | Yearly, Quarterly, Monthly | | Monash Time Series Forecasting Archive | CC BY 4.0 | Download |
| `m3` | M3 (2000) | 3,003 | Yearly, Quarterly, Monthly, Other | | Monash Time Series Forecasting Archive | CC BY 4.0 | Download |
| `m4` | M4 (2018) | 100,000 | Yearly, Quarterly, Monthly, Weekly, Daily, Hourly | 61 | Mcompetitions/M4-methods | None stated | Download |

`data/catalogue.toml` describes each competition: its source, the revision of M4's repository, the licence, the papers (keys of PollisReferences), and each file with its address and SHA-256.

## Download

`download(id)` fetches the files of a competition from its source, checks each against the SHA-256 of the catalogue, and converts them on this computer into `~/.pollis/competitions/<id>`:

- `series.parquet`: series (a number), competition, name (as the source names it), frequency, period (the seasonal period), horizon, domain and start (as the source gives it);
- `observations.parquet`: series, t (from 1), value, and split, `train` for the values the forecasters saw and `test` for those their forecasts were scored on;
- for M4, `entries.parquet` (entry, name, kind, method, team, affiliation, rank) from `Submission Info.xlsx`, and `published_scores.parquet` (entry, measure, breakdown, level, value), the sMAPE, MASE and OWA of each entry by frequency and by domain, from `Evaluation and Ranks.xlsx`.

The files of the source are removed once converted. A file whose SHA-256 is not that of the catalogue stops the download: its source has changed.

`download_forecasts(id; entries)` adds the point forecasts of the entries named, or of all 61 when none are, in `forecasts/<entry>.parquet` (entry, series, h, value). M4's forecasts come as RAR archives, which bsdtar of libarchive (LibArchive_jll) reads. All of them take 460 MB to download.

The tables are Parquet files, which Julia reads through DuckDB, filtered first: `query(sql)` runs any SQL on them.

In each series of the Monash archive, the values the forecasters saw come first, then the values of the horizon: so it is for the 23,000 series of M4 Yearly, which the archive and the files of M4's organisers give with the same values. The archive gives no domain.

`data/others.toml` holds competitions that are not M competitions, kept for a later group: the package does not read it.

## Licence

MIT, for the code. The data keep the terms of their source: the Monash archive puts CC BY 4.0 on its files; the repository of M4 states no licence.
