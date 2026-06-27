#!/bin/bash
# Triggered on a short press (< 0.7s) of the power button.
# Debounced to prevent continuous triggers under 1.0s.

/usr/local/bin/ucs device_sleep_or_resume
