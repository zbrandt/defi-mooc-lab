#!/bin/bash
docker container prune --force
docker image rm defi-mooc-lab2
docker build -t defi-mooc-lab2 .
docker run -e ALCHE_API="aCcG3XtUoJrFTkANwKMD4txqyBQcp-Qm" -it defi-mooc-lab2 npm test
