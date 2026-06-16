# Serverless Function Templates

Minimal serverless function handlers with input validation and structured error responses (400 for bad input, 500 for unexpected errors). The AWS and GCP examples implement the same toy calculation endpoint (add `num1` + `num2` from a JSON body) so the platform differences are easy to compare.

| Template | Platform | Notes |
| --- | --- | --- |
| [`awsLambda.py`](./awsLambda.py) | AWS Lambda (Python) | Standard `lambda_handler(event, context)`; parses JSON from `event["body"]` (API Gateway-style) |
| [`gcpFunction.py`](./gcpFunction.py) | Google Cloud Functions (Python) | HTTP function using Flask's `request`/`jsonify` |
| [`netlifyFunction.js`](./netlifyFunction.js) | Netlify Functions (Node.js) | `exports.handler` that fetches JSON from an upstream API and returns it; uses `node-fetch` (on Node 18+ you can use the built-in `fetch` instead) |

## Usage

Copy the file into your project's functions directory, replace the example logic, and deploy with the platform's tooling (AWS SAM/console, `gcloud functions deploy`, or Netlify's `netlify/functions/` convention).
