<?php

/**
 *
 * WHMCS Freeradius Server Module
 * Version	  : 2.0.2
 * Author     : Birender Singh Budhwar
 * Release on : 01.04.2023
 * Website    : https://www.bsbdips.com
 *
 **/

use WHMCS\Database\Capsule;

// Define product configuration options.
function freeradius_ConfigOptions()
{
    $configarray = array(
     "Group Name" => array( "Type" => "text", "Size" => "25", "Default" => "", "Description" => "Enter Data Plan Name"),
	 "Usage Limit" => array( "Type" => "text", "Size" => "25", "Default" => "", "Description" => "Data limit in bytes. Use 0 or leave blank to disable"),
	 "Rate Limit" => array( "Type" => "text", "Size" => "25", "Default" => "", "Description" => "Bandwidth Rate limit. Use 10M/10M to setup download and upload limit."),
	 "Session Limit" => array( "Type" => "text", "Size" => "25", "Default" => "", "Description" => "Set user session limit, Use 0 or leave blank to disable"),
    );
    return $configarray;
}

// Define user manual or download link to any file
function freeradius_download($params) {
   header( 'Location: https://support.bsbdips.com' ) ;
}

Further code starts here...
