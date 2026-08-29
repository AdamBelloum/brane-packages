# The package metadata
name: hello_world
version: 1.0.0
kind: ecu             # <--- THIS IS THE MISSING FIELD THAT TRIGGERED THE ERROR

# (Optional) Packages or system dependencies you need inside the container
dependencies:
  - python3
  - python3-yaml

# Specify the files to copy over (relative to this container.yml file)
files:
  - hello_world.py

# Specify which file to run
entrypoint:
  kind: task
  exec: hello_world.py

# The functions (actions) your package implements
actions:
  "hello_world":
    command:
    input:
    output:
      - name: output
        type: string
