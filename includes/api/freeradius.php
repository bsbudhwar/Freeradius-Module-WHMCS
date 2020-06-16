<?php

//Requirements
  require(ROOTDIR."/configuration.php");
//end

//Return defaults
  $return['result'] = 'error';
  $return['message'] = 'Unknow WHMCS API error';
//end

//Check if username has been posted
  if( isset( $_POST['service_username'] ) ) {
    $username = $_POST['service_username'];
  }
  else {
    $return['message'] = 'No username supplied';
    echo json_encode( $return );
    return;
  }
//end

Then PHP code for futher processing of API.....
