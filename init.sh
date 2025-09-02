#!/bin/env bash

terraform init -input=false -backend=false
terraform validate
