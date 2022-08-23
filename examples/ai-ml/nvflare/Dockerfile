FROM python:3.7-buster

# Cannot use latest published version so we need to clone and install source
RUN git clone https://github.com/NVIDIA/NVFlare.git \
    && python3 -m pip install -e NVFlare

# Cannot run `provision` with an auto-accept flag so we have to copy
COPY project.yml .
RUN provision -p project.yml \
    # not sure why we need to do this
    && mv /workspace/example_project/prod_00/* /workspace/
