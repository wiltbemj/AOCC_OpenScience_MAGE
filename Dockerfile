FROM ubuntu:20.04 as build


RUN apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates imagemagick python3.9 python3-pip && \
  rm -rf /var/lib/apt/lists/*



# Now comes the Jupyter part
WORKDIR /
ARG OWNER=jupyter

ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="100"

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# Install all OS dependencies for notebook server that starts but lacks all
# features (e.g., download as all possible file formats)
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends \
    # - bzip2 is necessary to extract the micromamba executable.
    bzip2 \
    ca-certificates \
    fonts-liberation \
    locales vim emacs \
    # - pandoc is used to convert notebooks to html files
    #   it's not present in arm64 ubuntu image, so we install it here
    # pandoc \
    # - run-one - a wrapper script that runs no more
    #   than one unique  instance  of  some  command with a unique set of arguments,
    #   we use `run-one-constantly` to support `RESTARTABLE` option
    run-one \
    # sudo \
    # - tini is installed as a helpful container entrypoint that reaps zombie
    #   processes and such of the actual executable we want to start, see
    #   https://github.com/krallin/tini#why-tini for details.
    tini \
    wget \
    # dependencies for IParaView Jupyter Kernel that can not be installed with conda
    git \
    gcc \
    g++ \
    gfortran \
    make \
    cmake \
    xvfb \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    mesa-common-dev \
    # the next three are dependencies for the vtk package that is otherwise not installed correct
    ffmpeg \
    libsm6 \
    libxext6 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen &&\
    wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda.sh && \
     /bin/bash ~/miniconda.sh -b -p /opt/conda


# Configure environment
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH="${CONDA_DIR}/bin:${PATH}" \
    HOME="/home/${NB_USER}"

# Copy a script that we will use to correct permissions after running certain commands
COPY fix-permissions /usr/local/bin/fix-permissions
RUN chmod a+rx /usr/local/bin/fix-permissions &&\
# Enable prompt color in the skeleton .bashrc before creating the default NB_USER
# hadolint ignore=SC2016
   sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /etc/skel/.bashrc && \
   # Add call to conda init script see https://stackoverflow.com/a/58081608/4413446
   echo 'eval "$(command conda shell.bash hook 2> /dev/null)"' >> /etc/skel/.bashrc

# Create NB_USER with name jovyan user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "auth requisite pam_deny.so" >> /etc/pam.d/su && \
    useradd -l -m -s /bin/bash -N -u "${NB_UID}" "${NB_USER}" && \
    mkdir -p "${CONDA_DIR}" && \
    chown "${NB_USER}:${NB_GID}" "${CONDA_DIR}" && \
    chmod g+w /etc/passwd && \
    fix-permissions "${HOME}" 

USER root

# Pin python version here, or set it to "default"
ARG PYTHON_VERSION=3.9

# Setup work directory for backward-compatibility
RUN mkdir "/home/${NB_USER}/work" && \
    fix-permissions "/home/${NB_USER}" 

ARG PARAVIEW_VERSION=5.11.1
#ARG PARAVIEW_BUILD=py39h03a2555_101_qt

RUN apt upgrade -y && conda install -c conda-forge python="${PYTHON_VERSION}" \
      # paraview="${PARAVIEW_VERSION}"="${PARAVIEW_BUILD}" \
       paraview="${PARAVIEW_VERSION}" \
       boost=1.78.0 \
       cli11 \
       nlohmann_json \
       eigen \
       notebook \
       jupyterlab \
       jupyterhub \
       ipyvtklink 


COPY python3.9requirements.txt .
RUN jupyter notebook --generate-config && \
    /opt/conda/bin/pip3 install --upgrade pip setuptools wheel && \
    #conda remove --force matplotlib &&\
    #pip install --no-cache-dir "matplotlib==3.1.2"  &&\
    /opt/conda/bin/pip3 install --no-cache-dir  --no-use-pep517 -r python3.9requirements.txt && \
    #/opt/conda/bin/pip3  --no-cache-dir install -r python3.9requirements.txt && \
    #pip install -r python3.9requirements.txt &&\
    #/opt/conda/bin/pip3 install --no-cache-dir  --no-use-pep517 -r environment-kaipy.yml &&\ 
    conda clean -a -y && \
    jupyter lab clean && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    fix-permissions "/home/${NB_USER}"

ENV ParaView_DIR=/home/jovyan/.conda/pkgs/paraview-${PARAVIEW_VERSION}" \
    CMAKE_INSTALL_PREFIX=/home/jovyan/.local/share/jupyter/kernels \
    PYTHONPATH=/home/jovyan/./lib/python3.9/site-packages \
    LD_LIBRARY_PATH=/home/jovyan/.conda/pkgs/paraview-${PARAVIEW_VERSION}"/lib:/home/jovyan/.conda/envs/paraview/lib \
    PATH=/opt/conda/bin:/opt/conda/condabin:/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN git clone https://gitlab.kitware.com/paraview/iparaview-kernel.git &&\
#COPY iparaview-kernel ./iparaview-kernel

   cd iparaview-kernel/ && ls && cmake -S . && cmake --build . --target install &&\
   pip install jupyterlab_h5web[full]

EXPOSE 8888

# Configure container startup
COPY start_xvfb.sh /sbin/start_xvfb.sh
RUN chmod a+x /sbin/start_xvfb.sh

ENTRYPOINT ["tini", "-g", "--", "start_xvfb.sh"]
CMD ["start-notebook.sh"]

# Copy local files as late as possible to avoid cache busting
COPY start.sh start-notebook.sh start-singleuser.sh /usr/local/bin/
# Currently need to have both jupyter_notebook_config and jupyter_server_config to support classic and lab
COPY jupyter_server_config.py /etc/jupyter/

# Fix permissions on /etc/jupyter as root
USER root

# Legacy for Jupyter Notebook Server, see: [#1205](https://github.com/jupyter/docker-stacks/issues/1205)
RUN sed -re "s/c.ServerApp/c.NotebookApp/g" \
    /etc/jupyter/jupyter_server_config.py > /etc/jupyter/jupyter_notebook_config.py && \
    fix-permissions /etc/jupyter/ &&\
    fix-permissions /usr/local/bin

# HEALTHCHECK documentation: https://docs.docker.com/engine/reference/builder/#healthcheck
# This healtcheck works well for `lab`, `notebook`, `nbclassic`, `server` and `retro` jupyter commands
# https://github.com/jupyter/docker-stacks/issues/915#issuecomment-1068528799
HEALTHCHECK  --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -O- --no-verbose --tries=1 --no-check-certificate \
    http${GEN_CERT:+s}://localhost:8888${JUPYTERHUB_SERVICE_PREFIX:-/}api || exit 1

# Run the fix-permissions for home as there are still some problems
RUN fix-permissions /home/$NB_USER

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}

ENV PYTHONPATH="${PYTHONPATH}:/home/jovyan/.local/lib/python3.9/site-packages/"
ENV XDG_RUNTIME_DIR="/tmp/runtime-${NB_USER}"
RUN echo "ulimit -s unlimited" >> /home/jovyan/.bashrc
COPY globus_client_start.ipynb ${HOME}
WORKDIR "${HOME}"
