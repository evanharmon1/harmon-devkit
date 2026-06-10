// Import modules
const fetch = require('node-fetch');

// Define the handler for the Netlify function
exports.handler = async function(event, context) {
  try {
    // Example API endpoint to fetch data from (replace this with your actual API)
    const apiUrl = 'https://jsonplaceholder.typicode.com/todos/1';

    // Fetch data from the API
    const response = await fetch(apiUrl);

    // If the response is not OK (status code outside 200–299 range), throw an error
    if (!response.ok) {
      throw new Error(`HTTP error! Status: ${response.status}`);
    }

    // Parse the response data as JSON
    const data = await response.json();

    // Return the successful response with the fetched data
    return {
      statusCode: 200,
      body: JSON.stringify({
        message: 'Success',
        data: data
      }),
    };
  } catch (error) {
    // Handle errors, returning a 500 status code and the error message
    return {
      statusCode: 500,
      body: JSON.stringify({
        message: 'Failed to fetch data',
        error: error.message,
      }),
    };
  }
};
