#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# ==============================================================================
#                       pythonScriptTemplate.py
# ==============================================================================
# Template to create new python cli scripts.
# Author: Evan Harmon
# Usage: python script.py --input input.txt --output output.txt --verbose

import argparse
import logging
import sys

__version__ = "1.0.0"

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler()],
)

logger = logging.getLogger(__name__)


def parse_args():
    """
    Parse command line arguments.
    """
    parser = argparse.ArgumentParser(
        description="A Python CLI script",
        epilog="Example: python script.py --input file.txt",
    )

    # Define arguments
    parser.add_argument(
        "-i", "--input", type=str, required=True, help="Path to the input file"
    )

    parser.add_argument(
        "-o",
        "--output",
        type=str,
        default="output.txt",
        help="Path to the output file (default: output.txt)",
    )

    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable verbose mode"
    )

    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
        help="Show the script version and exit",
    )

    return parser.parse_args()


def validate_args(args):
    """
    Validate command line arguments.
    """
    # Example validation: check if the input file exists
    if not args.input.endswith(".txt"):
        logger.error("Invalid input file. Must be a .txt file.")
        sys.exit(1)

    logger.info(f"Using input file: {args.input}")
    logger.info(f"Output will be saved to: {args.output}")


def process_file(input_path, output_path):
    """
    Placeholder for the main file processing logic.
    """
    try:
        with open(input_path, "r") as infile:
            content = infile.read()

        # Example processing: just write the content to the output file
        with open(output_path, "w") as outfile:
            outfile.write(content)

        logger.info(f"File processed successfully. Output saved to {output_path}")

    except FileNotFoundError:
        logger.error(f"File {input_path} not found.")
        sys.exit(1)
    except Exception as e:
        logger.error(f"An error occurred: {str(e)}")
        sys.exit(1)


def main():
    """
    Main entry point of the script.
    """
    args = parse_args()

    # Enable verbose mode if requested
    if args.verbose:
        logger.setLevel(logging.DEBUG)

    logger.debug("Arguments parsed successfully.")

    # Validate the arguments
    validate_args(args)

    # Process the file
    process_file(args.input, args.output)


if __name__ == "__main__":
    main()
