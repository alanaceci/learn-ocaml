// TODO
// config with database 

// get current input in exercise text area
function track_local_changes() {
    // innerHTML contains nested HTML tags which encapsulate the code 
    const exercise = document.getElementsByClassName("ace_layer ace_text-layer")[0].innerHTML
    // strip of HTML to get raw code 
    const stringSolution = strip(exercise)
    console.log(stringSolution)    
    // TODO: convert exercise to JSON Obj, send to DATABASE
}

function strip(html){
	var tmp = document.createElement("DIV");
    tmp.innerHTML= html
    return tmp.textContent || tmp.innerText || "" 
}

function stripHTML(html){
    var doc = new DOMParser().parseFromString(html, 'text/html');
    return doc.body.textContent || "";
 }
// call function every 2 minutes
setInterval(function() { track_local_changes(); } , 120000);
