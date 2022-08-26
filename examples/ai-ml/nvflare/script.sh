#!/usr/bin/env bash

pipenv install
pipenv run provision
mv /workspace/example_project/prod_00/* /workspace/

