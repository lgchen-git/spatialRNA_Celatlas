# Celatlas Spatial RNA

Reusable Snakemake/Docker wrapper for Celatlas spatial RNA processing. The
workflow keeps configuration, container entry points, pipeline rules, reports,
and tests separate from external inputs and references.

Real sample sheets, FASTQ files, reference bundles, result directories, and
server-specific run instructions are excluded from this public release.

~~~bash
make lint
make smoke
~~~

Provide a local sample sheet and external read-only data roots before a
production run.
