"""YAML loading for the validation scripts.

PyYAML's safe loader stops on a bare `=` (the YAML 1.1 "value" tag), which appears as an enum
value in the Prometheus Operator CRDs. It is just the string "=".
"""
import yaml


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def load_all(stream):
    return yaml.load_all(stream, Loader=Loader)
