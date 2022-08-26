FROM python:3.7-buster

# Cannot use latest published version so we need to clone and install source
RUN git clone https://github.com/NVIDIA/NVFlare.git \
    && python3 -m pip install -e NVFlare
