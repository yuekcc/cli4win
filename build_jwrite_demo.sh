#!/bin/bash
set -ex

c3c compile --libdir ./ --lib jwrite jwrite_demo.c3
./jwrite_demo