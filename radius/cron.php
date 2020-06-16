<?php

//Check if script is already running
  $tmpfilename = "/tmp/freeradius_cron.pid";
  if (!($tmpfile = @fopen($tmpfilename,"w"))){
    return 0;
  }

  if (!@flock( $tmpfile, LOCK_EX | LOCK_NB, $wouldblock) || $wouldblock){
    @fclose($tmpfile);
    return 0;
  }
//end

//Include some files
  require(dirname(__FILE__).'/config.php');
//end

//Set some varibles
  if($general_timezone != '') { date_default_timezone_set($general_timezone); }
  $radius_users = array();
//end

//Curl is important
  if (!function_exists('curl_init')){
    echo "cURL is not installed\n";
    die('cURL is not installed');
  }
//

//Make sure the WHMCS API details are present & tested
  if( ( $whmcs_api_url == "" ) || ( $whmcs_api_secret == "" ) || ( $whmcs_api_identifier == "" ) ) {
    die( "WHMCS API details missing\n" );
  }
//end

Then connect to database for further processing

{PHP CODE}
