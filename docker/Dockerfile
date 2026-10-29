FROM ubuntu:20.04

# This offline build deliberately uses the tested local Conda environment.  Its
# original prefix is preserved because Conda console-script shebangs are prefix
# absolute.  The runtime wrapper constrains execution to CPU resources.
ENV PATH=/opt/project/software/miniconda3/envs/spatialRNA/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    MPLCONFIGDIR=/work/tmp/mpl \
    NUMBA_CACHE_DIR=/work/tmp/numba \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

COPY spatialRNA_env /opt/project/software/miniconda3/envs/spatialRNA
COPY celatlas_src /opt/project/software/Celatlas_spatial

RUN mkdir -p /work/tmp/mpl /work/tmp/numba \
 && chmod 1777 /work/tmp /work/tmp/mpl /work/tmp/numba \
 && chmod 755 /opt/project/software/Celatlas_spatial/Celatlas.sh

WORKDIR /work
ENTRYPOINT ["/opt/project/software/Celatlas_spatial/Celatlas.sh"]
CMD ["--help"]
