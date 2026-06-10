import json


def lambda_handler(event, context):
    try:
        # Parse the input from the event (assumed to be passed as JSON)
        body = json.loads(event.get("body", "{}"))

        # Extract two numbers from the input
        num1 = body.get("num1")
        num2 = body.get("num2")

        # Validate input
        if num1 is None or num2 is None:
            raise ValueError("Both 'num1' and 'num2' are required.")

        # Ensure the inputs are numbers
        if not isinstance(num1, (int, float)) or not isinstance(num2, (int, float)):
            raise ValueError("'num1' and 'num2' must be numbers.")

        # Perform a simple calculation (e.g., addition)
        result = num1 + num2

        # Return the result
        return {
            "statusCode": 200,
            "body": json.dumps({"message": "Calculation successful", "result": result}),
        }

    except ValueError as ve:
        # Handle value errors (e.g., missing or invalid input)
        return {"statusCode": 400, "body": json.dumps({"error": str(ve)})}

    except Exception as e:
        # Handle any unexpected errors
        return {
            "statusCode": 500,
            "body": json.dumps(
                {"error": "An internal error occurred", "details": str(e)}
            ),
        }
