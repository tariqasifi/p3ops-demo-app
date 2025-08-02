#!/bin/bash
set -e


groupadd -r appgroup
useradd -r -g appgroup app


mkdir -p /app
chown -R app:appgroup /app
