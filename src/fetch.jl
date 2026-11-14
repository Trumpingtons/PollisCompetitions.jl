"""The SHA-256 of the file at `path`, in hexadecimal."""
sha256_of(path) = open(io -> bytes2hex(sha256(io)), path)

"""
	fetch_file(file, folder)

The file of the catalogue `file` (its `url`, `name` and `sha256`), downloaded into `folder` unless it is there already
with the right checksum. A file whose SHA-256 is not the catalogue's is removed and the download fails: the source has
changed since the catalogue was written.
"""
function fetch_file(file, folder)
	path = joinpath(folder, file["name"])
	isfile(path) && sha256_of(path) == file["sha256"] && return path
	mkpath(folder)
	partial = path * ".part"
	try
		Downloads.download(file["url"], partial)
	catch
		rm(partial; force = true)
		rethrow()
	end
	checksum = sha256_of(partial)
	if checksum != file["sha256"]
		page = startswith(lstrip(String(read(partial, 512))), "<")
		rm(partial; force = true)
		# A busy source, such as a file of Google Drive downloaded too often in a day, answers a page in its place
		page && error("$(file["url"]) answered a page, not $(file["name"]): the source may be busy. Try again later.")
		error("$(file["name"]) from $(file["url"]) is not the file of the catalogue: its SHA-256 is $(checksum), not $(file["sha256"]). The source has changed.")
	end
	mv(partial, path; force = true)
end

"""
	extract(archive, folder)

The files of `archive` (zip or RAR) extracted into `folder` by bsdtar of libarchive, which reads both, as a list of
their paths.
"""
function extract(archive, folder)
	mkpath(folder)
	run(`$(bsdtar()) -xf $(archive) -C $(folder)`)
	[joinpath(root, name) for (root, _, names) in walkdir(folder) for name in names]
end

"""The one file of `paths` whose name ends with `extension`, or an error naming `archive`."""
function only_file(paths, extension, archive)
	found = filter(path -> endswith(lowercase(path), extension), paths)
	length(found) == 1 || error("$(basename(archive)) holds $(length(found)) files $(extension), not one.")
	only(found)
end
