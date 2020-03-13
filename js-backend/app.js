const express = require('express');
const bodyParser = require('body-parser');
const app = express();
const port = 8000;
const mongoose = require('mongoose');
app.use(bodyParser.text({ type: "application/json" }));

// connect to database
mongoose.connect('mongodb://localhost/learnocaml')
const db = mongoose.connection;
db.on('error', console.error.bind(console, 'MongoDB connection error:'));

// Access Control
app.use(function(req, res, next) {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
    next();
  });

// receive the POST from the client javascript file
app.post("/", function (req, res)
{
  if (req.body)
  {
    const solution = JSON.parse( req.body ); // parse req.body as an object
    db.collection('studentcode').insertOne(solution);
    console.log(solution);
    res.sendStatus(200); // success status
  }
  else
  {
    res.sendStatus(400); // error status
  }
});  


app.listen(port, () => {
  console.log(`Server running on port${port}`);
});