-- phpMyAdmin SQL Dump
-- version 5.2.0
-- https://www.phpmyadmin.net/
--
-- Host: localhost
-- Generation Time: Aug 18, 2023 at 09:54 AM
-- Server version: 8.0.31-commercial
-- PHP Version: 8.1.21

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `radius`
--

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `fr_allocate_previous_or_new_framedipaddress` (IN `v_pool_name` VARCHAR(64), IN `v_username` VARCHAR(64), IN `v_callingstationid` VARCHAR(64), IN `v_nasipaddress` VARCHAR(15), IN `v_pool_key` VARCHAR(64), IN `v_lease_duration` INT)   proc:BEGIN
        DECLARE r_address VARCHAR(15);

        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        START TRANSACTION;

        -- Reissue an existing IP address lease when re-authenticating a session
        --
        SELECT framedipaddress INTO r_address
        FROM radippool
        WHERE pool_name = v_pool_name
                AND expiry_time > NOW()
                AND username = v_username
                AND callingstationid = v_callingstationid
        LIMIT 1
        FOR UPDATE;
--      FOR UPDATE SKIP LOCKED;  -- Better performance, but limited support

        -- Reissue an user's previous IP address, provided that the lease is
        -- available (i.e. enable sticky IPs)
        --
        -- When using this SELECT you should delete the one above. You must also
        -- set allocate_clear = "" in queries.conf to persist the associations
        -- for expired leases.
        --
        -- SELECT framedipaddress INTO r_address
        -- FROM radippool
        -- WHERE pool_name = v_pool_name
        --         AND username = v_username
        --         AND callingstationid = v_callingstationid
        -- LIMIT 1
        -- FOR UPDATE;
        -- -- FOR UPDATE SKIP LOCKED;  -- Better performance, but limited support

        -- If we didn't reallocate a previous address then pick the least
        -- recently used address from the pool which maximises the likelihood
        -- of re-assigning the other addresses to their recent user
        --
        IF r_address IS NULL THEN
                SELECT framedipaddress INTO r_address
                FROM radippool
                WHERE pool_name = v_pool_name
                        AND ( expiry_time < NOW() OR expiry_time IS NULL )
                ORDER BY
                        expiry_time
                LIMIT 1
                FOR UPDATE;
--              FOR UPDATE SKIP LOCKED;  -- Better performance, but limited support
        END IF;

        -- Return nothing if we failed to allocated an address
        --
        IF r_address IS NULL THEN
                COMMIT;
                LEAVE proc;
        END IF;

        -- Update the pool having allocated an IP address
        --
        UPDATE radippool
        SET
                nasipaddress = v_nasipaddress,
                pool_key = v_pool_key,
                callingstationid = v_callingstationid,
                username = v_username,
                expiry_time = NOW() + INTERVAL v_lease_duration SECOND
        WHERE framedipaddress = r_address;

        COMMIT;

        -- Return the address that we allocated
        SELECT r_address;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `fr_new_data_usage_period` ()  SQL SECURITY INVOKER BEGIN

    DECLARE v_start DATETIME;
    DECLARE v_end DATETIME;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT IFNULL(DATE_ADD(MAX(period_end), INTERVAL 1 SECOND), FROM_UNIXTIME(0)) INTO v_start FROM data_usage_by_period;
    SELECT NOW() INTO v_end;

    START TRANSACTION;

    --
    -- Add the data usage for the sessions that were active in the current
    -- period to the table. Include all sessions that finished since the start
    -- of this period as well as those still ongoing.
    --
    INSERT INTO data_usage_by_period (username, period_start, period_end, acctinputoctets, acctoutputoctets)
    SELECT *
    FROM (
        SELECT
            username,
            v_start,
            v_end,
            SUM(acctinputoctets) AS acctinputoctets,
            SUM(acctoutputoctets) AS acctoutputoctets
        FROM ((
            SELECT
                username, acctinputoctets, acctoutputoctets
            FROM
                radacct
            WHERE
                acctstoptime > v_start
        ) UNION ALL (
            SELECT
                username, acctinputoctets, acctoutputoctets
            FROM
                radacct
            WHERE
                acctstoptime IS NULL
        )) AS a
        GROUP BY
            username
    ) AS s
    ON DUPLICATE KEY UPDATE
        acctinputoctets = data_usage_by_period.acctinputoctets + s.acctinputoctets,
        acctoutputoctets = data_usage_by_period.acctoutputoctets + s.acctoutputoctets,
        period_end = v_end;

    --
    -- Create an open-ended "next period" for all ongoing sessions and carry a
    -- negative value of their data usage to avoid double-accounting when we
    -- process the next period. Their current data usage has already been
    -- allocated to the current and possibly previous periods.
    --
    INSERT INTO data_usage_by_period (username, period_start, period_end, acctinputoctets, acctoutputoctets)
    SELECT *
    FROM (
        SELECT
            username,
            DATE_ADD(v_end, INTERVAL 1 SECOND),
            NULL,
            0 - SUM(acctinputoctets),
            0 - SUM(acctoutputoctets)
        FROM
            radacct
        WHERE
            acctstoptime IS NULL
        GROUP BY
            username
    ) AS s;

    COMMIT;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `fr_radacct_close_after_reload` ()  SQL SECURITY INVOKER BEGIN

    DECLARE v_a BIGINT(21);
    DECLARE v_z BIGINT(21);
    DECLARE v_updated BIGINT(21) DEFAULT 0;
    DECLARE v_last_report DATETIME DEFAULT 0;
    DECLARE v_last BOOLEAN DEFAULT FALSE;
    DECLARE v_batch_size INT(12);

    --
    --  This works for many circumstances
    --
    SET v_batch_size = 2500;

    SELECT MIN(radacctid) INTO v_a FROM radacct WHERE acctstoptime IS NULL;

    update_loop: LOOP

        SET v_z = NULL;
        SELECT radacctid INTO v_z FROM radacct WHERE radacctid > v_a ORDER BY radacctid LIMIT v_batch_size,1;

        IF v_z IS NULL THEN
            SELECT MAX(radacctid) INTO v_z FROM radacct;
            SET v_last = TRUE;
        END IF;

        UPDATE radacct a INNER JOIN nasreload n USING (nasipaddress)
        SET
            acctstoptime = n.reloadtime,
            acctsessiontime = UNIX_TIMESTAMP(n.reloadtime) - UNIX_TIMESTAMP(acctstarttime),
            acctterminatecause = 'NAS reboot'
        WHERE
            radacctid BETWEEN v_a AND v_z
            AND acctstoptime IS NULL
            AND acctstarttime < n.reloadtime;

        SET v_updated = v_updated + ROW_COUNT();

        SET v_a = v_z + 1;

        --
        --  Periodically report how far we've got
        --
        IF v_last_report != NOW() OR v_last THEN
            SELECT v_z AS latest_radacctid, v_updated AS sessions_closed;
            SET v_last_report = NOW();
        END IF;

        IF v_last THEN
            LEAVE update_loop;
        END IF;

    END LOOP;

END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `cui`
--

CREATE TABLE `cui` (
  `clientipaddress` varchar(46) NOT NULL DEFAULT '',
  `callingstationid` varchar(50) NOT NULL DEFAULT '',
  `username` varchar(64) NOT NULL DEFAULT '',
  `cui` varchar(32) NOT NULL DEFAULT '',
  `creationdate` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `lastaccounting` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

-- --------------------------------------------------------

--
-- Table structure for table `data_usage_by_period`
--

CREATE TABLE `data_usage_by_period` (
  `username` varchar(64) NOT NULL,
  `period_start` datetime NOT NULL,
  `period_end` datetime DEFAULT NULL,
  `acctinputoctets` bigint DEFAULT NULL,
  `acctoutputoctets` bigint DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `nas`
--

CREATE TABLE `nas` (
  `id` int NOT NULL,
  `nasname` varchar(128) NOT NULL,
  `shortname` varchar(32) DEFAULT NULL,
  `type` varchar(30) DEFAULT 'other',
  `ports` int DEFAULT NULL,
  `secret` varchar(60) NOT NULL DEFAULT 'secret',
  `server` varchar(64) DEFAULT NULL,
  `community` varchar(50) DEFAULT NULL,
  `description` varchar(200) DEFAULT 'RADIUS Client'
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `nasreload`
--

CREATE TABLE `nasreload` (
  `nasipaddress` varchar(15) NOT NULL,
  `reloadtime` datetime NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radacct`
--

CREATE TABLE `radacct` (
  `radacctid` bigint NOT NULL,
  `acctsessionid` varchar(64) NOT NULL DEFAULT '',
  `acctuniqueid` varchar(32) NOT NULL DEFAULT '',
  `username` varchar(64) NOT NULL DEFAULT '',
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `realm` varchar(64) DEFAULT '',
  `nasipaddress` varchar(15) NOT NULL DEFAULT '',
  `nasportid` varchar(32) DEFAULT NULL,
  `nasporttype` varchar(32) DEFAULT NULL,
  `acctstarttime` datetime DEFAULT NULL,
  `acctupdatetime` datetime DEFAULT NULL,
  `acctstoptime` datetime DEFAULT NULL,
  `acctinterval` int DEFAULT NULL,
  `acctsessiontime` int UNSIGNED DEFAULT NULL,
  `acctauthentic` varchar(32) DEFAULT NULL,
  `connectinfo_start` varchar(50) DEFAULT NULL,
  `connectinfo_stop` varchar(50) DEFAULT NULL,
  `acctinputoctets` bigint DEFAULT NULL,
  `acctoutputoctets` bigint DEFAULT NULL,
  `calledstationid` varchar(50) NOT NULL DEFAULT '',
  `callingstationid` varchar(50) NOT NULL DEFAULT '',
  `acctterminatecause` varchar(32) NOT NULL DEFAULT '',
  `servicetype` varchar(32) DEFAULT NULL,
  `framedprotocol` varchar(32) DEFAULT NULL,
  `framedipaddress` varchar(15) NOT NULL DEFAULT '',
  `framedipv6address` varchar(45) NOT NULL DEFAULT '',
  `framedipv6prefix` varchar(45) NOT NULL DEFAULT '',
  `framedinterfaceid` varchar(44) NOT NULL DEFAULT '',
  `delegatedipv6prefix` varchar(45) NOT NULL DEFAULT '',
  `class` varchar(64) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

--
-- Triggers `radacct`
--
DELIMITER $$
CREATE TRIGGER `chk_mac_after_insert` AFTER INSERT ON `radacct` FOR EACH ROW BEGIN
SET @mac = (SELECT count(*) from radcheck where username=New.username and attribute='Calling-Station-ID');
IF (@mac = 0) THEN
INSERT into radcheck (username,attribute,op,value) values (NEW.username,'Calling-Station-ID',':=',NEW.callingstationid);
END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `radacct_with_reloads`
-- (See below for the actual view)
--
CREATE TABLE `radacct_with_reloads` (
`acctauthentic` varchar(32)
,`acctinputoctets` bigint
,`acctinterval` int
,`acctoutputoctets` bigint
,`acctsessionid` varchar(64)
,`acctsessiontime` int unsigned
,`acctsessiontime_with_reloads` bigint
,`acctstarttime` datetime
,`acctstoptime` datetime
,`acctstoptime_with_reloads` datetime
,`acctterminatecause` varchar(32)
,`acctuniqueid` varchar(32)
,`acctupdatetime` datetime
,`calledstationid` varchar(50)
,`callingstationid` varchar(50)
,`class` varchar(64)
,`connectinfo_start` varchar(50)
,`connectinfo_stop` varchar(50)
,`delegatedipv6prefix` varchar(45)
,`framedinterfaceid` varchar(44)
,`framedipaddress` varchar(15)
,`framedipv6address` varchar(45)
,`framedipv6prefix` varchar(45)
,`framedprotocol` varchar(32)
,`groupname` varchar(64)
,`nasipaddress` varchar(15)
,`nasportid` varchar(32)
,`nasporttype` varchar(32)
,`radacctid` bigint
,`realm` varchar(64)
,`servicetype` varchar(32)
,`username` varchar(64)
);

-- --------------------------------------------------------

--
-- Table structure for table `radcheck`
--

CREATE TABLE `radcheck` (
  `id` int UNSIGNED NOT NULL,
  `username` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '==',
  `value` varchar(253) NOT NULL DEFAULT ''
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radgroupcheck`
--

CREATE TABLE `radgroupcheck` (
  `id` int UNSIGNED NOT NULL,
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '==',
  `value` varchar(253) NOT NULL DEFAULT ''
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radgroupreply`
--

CREATE TABLE `radgroupreply` (
  `id` int UNSIGNED NOT NULL,
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '=',
  `value` varchar(253) NOT NULL DEFAULT ''
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radhuntgroup`
--

CREATE TABLE `radhuntgroup` (
  `id` int UNSIGNED NOT NULL,
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `nasipaddress` varchar(15) NOT NULL DEFAULT '',
  `nasportid` varchar(15) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radippool`
--

CREATE TABLE `radippool` (
  `id` int UNSIGNED NOT NULL,
  `pool_name` varchar(30) NOT NULL,
  `framedipaddress` varchar(15) NOT NULL DEFAULT '',
  `nasipaddress` varchar(15) NOT NULL DEFAULT '',
  `calledstationid` varchar(30) NOT NULL,
  `callingstationid` varchar(30) NOT NULL,
  `expiry_time` datetime DEFAULT NULL,
  `username` varchar(64) NOT NULL DEFAULT '',
  `pool_key` varchar(30) NOT NULL DEFAULT ''
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radpostauth`
--

CREATE TABLE `radpostauth` (
  `id` int NOT NULL,
  `username` varchar(64) NOT NULL DEFAULT '',
  `pass` varchar(64) NOT NULL DEFAULT '',
  `reply` varchar(32) NOT NULL DEFAULT '',
  `authdate` timestamp(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radreply`
--

CREATE TABLE `radreply` (
  `id` int UNSIGNED NOT NULL,
  `username` varchar(64) NOT NULL DEFAULT '',
  `attribute` varchar(64) NOT NULL DEFAULT '',
  `op` char(2) NOT NULL DEFAULT '=',
  `value` varchar(253) NOT NULL DEFAULT ''
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `radusergroup`
--

CREATE TABLE `radusergroup` (
  `id` int UNSIGNED NOT NULL,
  `username` varchar(64) NOT NULL DEFAULT '',
  `groupname` varchar(64) NOT NULL DEFAULT '',
  `priority` int NOT NULL DEFAULT '1'
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `wimax`
--

CREATE TABLE `wimax` (
  `id` int NOT NULL,
  `username` varchar(64) NOT NULL DEFAULT '',
  `authdate` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `spi` varchar(16) NOT NULL DEFAULT '',
  `mipkey` varchar(400) NOT NULL DEFAULT '',
  `lifetime` int DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Structure for view `radacct_with_reloads`
--
DROP TABLE IF EXISTS `radacct_with_reloads`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `radacct_with_reloads`  AS SELECT `a`.`radacctid` AS `radacctid`, `a`.`acctsessionid` AS `acctsessionid`, `a`.`acctuniqueid` AS `acctuniqueid`, `a`.`username` AS `username`, `a`.`groupname` AS `groupname`, `a`.`realm` AS `realm`, `a`.`nasipaddress` AS `nasipaddress`, `a`.`nasportid` AS `nasportid`, `a`.`nasporttype` AS `nasporttype`, `a`.`acctstarttime` AS `acctstarttime`, `a`.`acctupdatetime` AS `acctupdatetime`, `a`.`acctstoptime` AS `acctstoptime`, `a`.`acctinterval` AS `acctinterval`, `a`.`acctsessiontime` AS `acctsessiontime`, `a`.`acctauthentic` AS `acctauthentic`, `a`.`connectinfo_start` AS `connectinfo_start`, `a`.`connectinfo_stop` AS `connectinfo_stop`, `a`.`acctinputoctets` AS `acctinputoctets`, `a`.`acctoutputoctets` AS `acctoutputoctets`, `a`.`calledstationid` AS `calledstationid`, `a`.`callingstationid` AS `callingstationid`, `a`.`acctterminatecause` AS `acctterminatecause`, `a`.`servicetype` AS `servicetype`, `a`.`framedprotocol` AS `framedprotocol`, `a`.`framedipaddress` AS `framedipaddress`, `a`.`framedipv6address` AS `framedipv6address`, `a`.`framedipv6prefix` AS `framedipv6prefix`, `a`.`framedinterfaceid` AS `framedinterfaceid`, `a`.`delegatedipv6prefix` AS `delegatedipv6prefix`, `a`.`class` AS `class`, coalesce(`a`.`acctstoptime`,if((`a`.`acctstarttime` < `n`.`reloadtime`),`n`.`reloadtime`,NULL)) AS `acctstoptime_with_reloads`, coalesce(`a`.`acctsessiontime`,if(((`a`.`acctstoptime` is null) and (`a`.`acctstarttime` < `n`.`reloadtime`)),(unix_timestamp(`n`.`reloadtime`) - unix_timestamp(`a`.`acctstarttime`)),NULL)) AS `acctsessiontime_with_reloads` FROM (`radacct` `a` left join `nasreload` `n` on((`a`.`nasipaddress` = `n`.`nasipaddress`)))  ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `cui`
--
ALTER TABLE `cui`
  ADD PRIMARY KEY (`username`,`clientipaddress`,`callingstationid`);

--
-- Indexes for table `data_usage_by_period`
--
ALTER TABLE `data_usage_by_period`
  ADD PRIMARY KEY (`username`,`period_start`),
  ADD KEY `idx_data_usage_by_period_period_start` (`period_start`),
  ADD KEY `idx_data_usage_by_period_period_end` (`period_end`);

--
-- Indexes for table `nas`
--
ALTER TABLE `nas`
  ADD PRIMARY KEY (`id`),
  ADD KEY `nasname` (`nasname`);

--
-- Indexes for table `nasreload`
--
ALTER TABLE `nasreload`
  ADD PRIMARY KEY (`nasipaddress`);

--
-- Indexes for table `radacct`
--
ALTER TABLE `radacct`
  ADD PRIMARY KEY (`radacctid`),
  ADD UNIQUE KEY `acctuniqueid` (`acctuniqueid`),
  ADD KEY `username` (`username`),
  ADD KEY `framedipaddress` (`framedipaddress`),
  ADD KEY `framedipv6address` (`framedipv6address`),
  ADD KEY `framedipv6prefix` (`framedipv6prefix`),
  ADD KEY `framedinterfaceid` (`framedinterfaceid`),
  ADD KEY `delegatedipv6prefix` (`delegatedipv6prefix`),
  ADD KEY `acctsessionid` (`acctsessionid`),
  ADD KEY `acctsessiontime` (`acctsessiontime`),
  ADD KEY `acctstarttime` (`acctstarttime`),
  ADD KEY `acctinterval` (`acctinterval`),
  ADD KEY `acctstoptime` (`acctstoptime`),
  ADD KEY `nasipaddress` (`nasipaddress`),
  ADD KEY `bulk_close` (`acctstoptime`,`nasipaddress`,`acctstarttime`);

--
-- Indexes for table `radcheck`
--
ALTER TABLE `radcheck`
  ADD PRIMARY KEY (`id`),
  ADD KEY `username` (`username`(32));

--
-- Indexes for table `radgroupcheck`
--
ALTER TABLE `radgroupcheck`
  ADD PRIMARY KEY (`id`),
  ADD KEY `groupname` (`groupname`(32));

--
-- Indexes for table `radgroupreply`
--
ALTER TABLE `radgroupreply`
  ADD PRIMARY KEY (`id`),
  ADD KEY `groupname` (`groupname`(32));

--
-- Indexes for table `radhuntgroup`
--
ALTER TABLE `radhuntgroup`
  ADD PRIMARY KEY (`id`),
  ADD KEY `nasipaddress` (`nasipaddress`);

--
-- Indexes for table `radippool`
--
ALTER TABLE `radippool`
  ADD PRIMARY KEY (`id`),
  ADD KEY `radippool_poolname_expire` (`pool_name`,`expiry_time`),
  ADD KEY `framedipaddress` (`framedipaddress`),
  ADD KEY `radippool_nasip_poolkey_ipaddress` (`nasipaddress`,`pool_key`,`framedipaddress`),
  ADD KEY `poolname_username_callingstationid` (`pool_name`,`username`,`callingstationid`);

--
-- Indexes for table `radpostauth`
--
ALTER TABLE `radpostauth`
  ADD PRIMARY KEY (`id`),
  ADD KEY `username` (`username`(32));

--
-- Indexes for table `radreply`
--
ALTER TABLE `radreply`
  ADD PRIMARY KEY (`id`),
  ADD KEY `username` (`username`(32));

--
-- Indexes for table `radusergroup`
--
ALTER TABLE `radusergroup`
  ADD PRIMARY KEY (`id`),
  ADD KEY `username` (`username`(32));

--
-- Indexes for table `wimax`
--
ALTER TABLE `wimax`
  ADD PRIMARY KEY (`id`),
  ADD KEY `username` (`username`),
  ADD KEY `spi` (`spi`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `nas`
--
ALTER TABLE `nas`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `radacct`
--
ALTER TABLE `radacct`
  MODIFY `radacctid` bigint NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=753;

--
-- AUTO_INCREMENT for table `radcheck`
--
ALTER TABLE `radcheck`
  MODIFY `id` int UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=1071;

--
-- AUTO_INCREMENT for table `radgroupcheck`
--
ALTER TABLE `radgroupcheck`
  MODIFY `id` int UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `radgroupreply`
--
ALTER TABLE `radgroupreply`
  MODIFY `id` int UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `radhuntgroup`
--
ALTER TABLE `radhuntgroup`
  MODIFY `id` int UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `radippool`
--
ALTER TABLE `radippool`
  MODIFY `id` int UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7355;

--
-- AUTO_INCREMENT for table `radpostauth`
--
ALTER TABLE `radpostauth`
  MODIFY `id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=42349;

--
-- AUTO_INCREMENT for table `radreply`
--
ALTER TABLE `radreply`
  MODIFY `id` int UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=129;

--
-- AUTO_INCREMENT for table `radusergroup`
--
ALTER TABLE `radusergroup`
  MODIFY `id` int UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=103;

--
-- AUTO_INCREMENT for table `wimax`
--
ALTER TABLE `wimax`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

DELIMITER $$
--
-- Events
--
CREATE DEFINER=`root`@`localhost` EVENT `fr_new_data_usage_period` ON SCHEDULE EVERY 1 DAY STARTS '2023-04-25 00:19:17' ON COMPLETION NOT PRESERVE ENABLE COMMENT 'Periodic Data Usage Reporting' DO BEGIN

    DECLARE v_start DATETIME;
    DECLARE v_end DATETIME;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT IFNULL(DATE_ADD(MAX(period_end), INTERVAL 1 SECOND), FROM_UNIXTIME(0)) INTO v_start FROM data_usage_by_period;
    SELECT NOW() INTO v_end;

    START TRANSACTION;

    --
    -- Add the data usage for the sessions that were active in the current
    -- period to the table. Include all sessions that finished since the start
    -- of this period as well as those still ongoing.
    --
    INSERT INTO data_usage_by_period (username, period_start, period_end, acctinputoctets, acctoutputoctets)
    SELECT *
    FROM (
        SELECT
            username,
            v_start,
            v_end,
            SUM(acctinputoctets) AS acctinputoctets,
            SUM(acctoutputoctets) AS acctoutputoctets
        FROM
            radacct
        WHERE
            acctstoptime > v_start OR
            acctstoptime IS NULL
        GROUP BY
            username
    ) AS s
    ON DUPLICATE KEY UPDATE
        acctinputoctets = data_usage_by_period.acctinputoctets + s.acctinputoctets,
        acctoutputoctets = data_usage_by_period.acctoutputoctets + s.acctoutputoctets,
        period_end = v_end;

    --
    -- Create an open-ended "next period" for all ongoing sessions and carry a
    -- negative value of their data usage to avoid double-accounting when we
    -- process the next period. Their current data usage has already been
    -- allocated to the current and possibly previous periods.
    --
    INSERT INTO data_usage_by_period (username, period_start, period_end, acctinputoctets, acctoutputoctets)
    SELECT *
    FROM (
        SELECT
            username,
            DATE_ADD(v_end, INTERVAL 1 SECOND),
            NULL,
            0 - SUM(acctinputoctets),
            0 - SUM(acctoutputoctets)
        FROM
            radacct
        WHERE
            acctstoptime IS NULL
        GROUP BY
            username
    ) AS s;

    COMMIT;

END$$

CREATE DEFINER=`root`@`localhost` EVENT `fr_radacct_close_after_reload` ON SCHEDULE EVERY 1 DAY STARTS '2023-04-25 00:32:43' ON COMPLETION NOT PRESERVE ENABLE COMMENT 'Periodic Data Usage Reporting' DO BEGIN

    DECLARE v_a BIGINT(21);
    DECLARE v_z BIGINT(21);
    DECLARE v_updated BIGINT(21) DEFAULT 0;
    DECLARE v_last_report DATETIME DEFAULT 0;
    DECLARE v_last BOOLEAN DEFAULT FALSE;
    DECLARE v_batch_size INT(12);

    --
    --  This works for many circumstances
    --
    SET v_batch_size = 2500;

    SELECT MIN(radacctid) INTO v_a FROM radacct WHERE acctstoptime IS NULL;

    update_loop: LOOP

        SET v_z = NULL;
        SELECT radacctid INTO v_z FROM radacct WHERE radacctid > v_a ORDER BY radacctid LIMIT v_batch_size,1;

        IF v_z IS NULL THEN
            SELECT MAX(radacctid) INTO v_z FROM radacct;
            SET v_last = TRUE;
        END IF;

        UPDATE radacct a INNER JOIN nasreload n USING (nasipaddress)
        SET
            acctstoptime = n.reloadtime,
            acctsessiontime = UNIX_TIMESTAMP(n.reloadtime) - UNIX_TIMESTAMP(acctstarttime),
            acctterminatecause = 'NAS reboot'
        WHERE
            radacctid BETWEEN v_a AND v_z
            AND acctstoptime IS NULL
            AND acctstarttime < n.reloadtime;

        SET v_updated = v_updated + ROW_COUNT();

        SET v_a = v_z + 1;

        --
        --  Periodically report how far we've got
        --
        IF v_last_report != NOW() OR v_last THEN
            SELECT v_z AS latest_radacctid, v_updated AS sessions_closed;
            SET v_last_report = NOW();
        END IF;

        IF v_last THEN
            LEAVE update_loop;
        END IF;

    END LOOP;

END$$

DELIMITER ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
