from setuptools import setup, find_packages

setup(
    name='plena_toolchain',
    version='0.1.0',
    packages=find_packages("tools"),
    package_dir={"": "tools"},
)
