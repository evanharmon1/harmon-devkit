import json
from flask import jsonify


def calculate(request):
    try:
        # Parse the request data (expected to be JSON)
        request_json = request.get_json(silent=True)

        # Validate input
        if request_json is None:
            raise ValueError("Request body must be valid JSON.")

        num1 = request_json.get("num1")
        num2 = request_json.get("num2")

        if num1 is None or num2 is None:
            raise ValueError("Both 'num1' and 'num2' are required.")

        # Ensure the inputs are numbers
        if not isinstance(num1, (int, float)) or not isinstance(num2, (int, float)):
            raise ValueError("'num1' and 'num2' must be numbers.")

        # Perform a simple calculation (e.g., addition)
        result = num1 + num2

        # Return the result
        return jsonify({"message": "Calculation successful", "result": result}), 200

    except ValueError as ve:
        # Handle value errors (e.g., missing or invalid input)
        return jsonify({"error": str(ve)}), 400

    except Exception as e:
        # Handle any unexpected errors
        return jsonify({"error": "An internal error occurred", "details": str(e)}), 500
