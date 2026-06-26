-- phpMyAdmin SQL Dump
-- version 5.1.0
-- https://www.phpmyadmin.net/
--
-- Host: 172.16.200.10:3306
-- Generation Time: Mar 22, 2021 at 10:31 AM
-- Server version: 5.7.33
-- PHP Version: 7.4.15

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `oai_db`
--

-- --------------------------------------------------------

--
-- Table structure for table `AccessAndMobilitySubscriptionData`
--
CREATE DATABASE oai_db;
USE oai_db;

CREATE TABLE `AccessAndMobilitySubscriptionData` (
  `ueid` varchar(15) NOT NULL,
  `servingPlmnid` varchar(15) NOT NULL,
  `supportedFeatures` varchar(50) DEFAULT NULL,
  `gpsis` json DEFAULT NULL,
  `internalGroupIds` json DEFAULT NULL,
  `sharedVnGroupDataIds` json DEFAULT NULL,
  `subscribedUeAmbr` json DEFAULT NULL,
  `nssai` json DEFAULT NULL,
  `ratRestrictions` json DEFAULT NULL,
  `forbiddenAreas` json DEFAULT NULL,
  `serviceAreaRestriction` json DEFAULT NULL,
  `coreNetworkTypeRestrictions` json DEFAULT NULL,
  `rfspIndex` int(10) DEFAULT NULL,
  `subsRegTimer` int(10) DEFAULT NULL,
  `ueUsageType` int(10) DEFAULT NULL,
  `mpsPriority` tinyint(1) DEFAULT NULL,
  `mcsPriority` tinyint(1) DEFAULT NULL,
  `activeTime` int(10) DEFAULT NULL,
  `sorInfo` json DEFAULT NULL,
  `sorInfoExpectInd` tinyint(1) DEFAULT NULL,
  `sorafRetrieval` tinyint(1) DEFAULT NULL,
  `sorUpdateIndicatorList` json DEFAULT NULL,
  `upuInfo` json DEFAULT NULL,
  `micoAllowed` tinyint(1) DEFAULT NULL,
  `sharedAmDataIds` json DEFAULT NULL,
  `odbPacketServices` json DEFAULT NULL,
  `serviceGapTime` int(10) DEFAULT NULL,
  `mdtUserConsent` json DEFAULT NULL,
  `mdtConfiguration` json DEFAULT NULL,
  `traceData` json DEFAULT NULL,
  `cagData` json DEFAULT NULL,
  `stnSr` varchar(50) DEFAULT NULL,
  `cMsisdn` varchar(50) DEFAULT NULL,
  `nbIoTUePriority` int(10) DEFAULT NULL,
  `nssaiInclusionAllowed` tinyint(1) DEFAULT NULL,
  `rgWirelineCharacteristics` varchar(50) DEFAULT NULL,
  `ecRestrictionDataWb` json DEFAULT NULL,
  `ecRestrictionDataNb` tinyint(1) DEFAULT NULL,
  `expectedUeBehaviourList` json DEFAULT NULL,
  `primaryRatRestrictions` json DEFAULT NULL,
  `secondaryRatRestrictions` json DEFAULT NULL,
  `edrxParametersList` json DEFAULT NULL,
  `ptwParametersList` json DEFAULT NULL,
  `iabOperationAllowed` tinyint(1) DEFAULT NULL,
  `wirelineForbiddenAreas` json DEFAULT NULL,
  `wirelineServiceAreaRestriction` json DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO `AccessAndMobilitySubscriptionData` (`ueid`, `servingPlmnid`, `nssai`) VALUES
('208950000000110', '20895','{\"defaultSingleNssais\": [{\"sst\": 1, \"sd\": \"000001\"}]}'),
('208950000000111', '20895','{\"defaultSingleNssais\": [{\"sst\": 1, \"sd\": \"000001\"}]}'),
('208950000000112', '20895','{\"defaultSingleNssais\": [{\"sst\": 1, \"sd\": \"000001\"}]}'),
('208950000000113', '20895','{\"defaultSingleNssais\": [{\"sst\": 1, \"sd\": \"000001\"}]}'),
('208950000000214', '20895','{\"defaultSingleNssais\": [{\"sst\": 2, \"sd\": \"000001\"}]}'),
('208950000000215', '20895','{\"defaultSingleNssais\": [{\"sst\": 2, \"sd\": \"000001\"}]}'),
('208950000000216', '20895','{\"defaultSingleNssais\": [{\"sst\": 2, \"sd\": \"000001\"}]}'),
('208950000000217', '20895','{\"defaultSingleNssais\": [{\"sst\": 2, \"sd\": \"000001\"}]}'),
('208950000000318', '20895','{\"defaultSingleNssais\": [{\"sst\": 3, \"sd\": \"000001\"}]}'),
('208950000000319', '20895','{\"defaultSingleNssais\": [{\"sst\": 3, \"sd\": \"000001\"}]}');
-- --------------------------------------------------------

--
-- Table structure for table `Amf3GppAccessRegistration`
--

CREATE TABLE `Amf3GppAccessRegistration` (
  `ueid` varchar(15) NOT NULL,
  `amfInstanceId` varchar(50) NOT NULL,
  `supportedFeatures` varchar(50) DEFAULT NULL,
  `purgeFlag` tinyint(1) DEFAULT NULL,
  `pei` varchar(50) DEFAULT NULL,
  `imsVoPs` json DEFAULT NULL,
  `deregCallbackUri` varchar(50) NOT NULL,
  `amfServiceNameDereg` json DEFAULT NULL,
  `pcscfRestorationCallbackUri` varchar(50) DEFAULT NULL,
  `amfServiceNamePcscfRest` json DEFAULT NULL,
  `initialRegistrationInd` tinyint(1) DEFAULT NULL,
  `guami` json NOT NULL,
  `backupAmfInfo` json DEFAULT NULL,
  `drFlag` tinyint(1) DEFAULT NULL,
  `ratType` json NOT NULL,
  `urrpIndicator` tinyint(1) DEFAULT NULL,
  `amfEeSubscriptionId` varchar(50) DEFAULT NULL,
  `epsInterworkingInfo` json DEFAULT NULL,
  `ueSrvccCapability` tinyint(1) DEFAULT NULL,
  `registrationTime` varchar(50) DEFAULT NULL,
  `vgmlcAddress` json DEFAULT NULL,
  `contextInfo` json DEFAULT NULL,
  `noEeSubscriptionInd` tinyint(1) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Table structure for table `AuthenticationStatus`
--

CREATE TABLE `AuthenticationStatus` (
  `ueid` varchar(20) NOT NULL,
  `nfInstanceId` varchar(50) NOT NULL,
  `success` tinyint(1) NOT NULL,
  `timeStamp` varchar(50) NOT NULL,
  `authType` varchar(25) NOT NULL,
  `servingNetworkName` varchar(50) NOT NULL,
  `authRemovalInd` tinyint(1) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Table structure for table `AuthenticationSubscription`
--

CREATE TABLE `AuthenticationSubscription` (
  `ueid` varchar(20) NOT NULL,
  `authenticationMethod` varchar(25) NOT NULL,
  `encPermanentKey` varchar(50) DEFAULT NULL,
  `protectionParameterId` varchar(50) DEFAULT NULL,
  `sequenceNumber` json DEFAULT NULL,
  `authenticationManagementField` varchar(50) DEFAULT NULL,
  `algorithmId` varchar(50) DEFAULT NULL,
  `encOpcKey` varchar(50) DEFAULT NULL,
  `encTopcKey` varchar(50) DEFAULT NULL,
  `vectorGenerationInHss` tinyint(1) DEFAULT NULL,
  `n5gcAuthMethod` varchar(15) DEFAULT NULL,
  `rgAuthenticationInd` tinyint(1) DEFAULT NULL,
  `supi` varchar(20) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Dumping data for table `AuthenticationSubscription`
--
INSERT INTO `AuthenticationSubscription` (`ueid`, `authenticationMethod`, `encPermanentKey`, `protectionParameterId`, `sequenceNumber`, `authenticationManagementField`, `algorithmId`, `encOpcKey`, `encTopcKey`, `vectorGenerationInHss`, `n5gcAuthMethod`, `rgAuthenticationInd`, `supi`) VALUES
('208950000000031', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000031'),
('208950000000032', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000032'),
('208950000000033', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000033'),
('208950000000034', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000034'),
('208950000000035', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000035'),
('208950000000036', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000036'),
('208950000000037', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000037'),
('208950000000038', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000038'),
('208950000000039', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000039'),
('208950000000040', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000040'),
('208950000000041', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000041'),
('208950000000042', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000042'),
('208950000000043', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000043'),
('208950000000044', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000044'),
('208950000000045', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000045'),
('208950000000046', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000046'),
('208950000000047', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000047'),
('208950000000048', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000048'),
('208950000000049', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000049'),
('208950000000050', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000050'),
('208950000000051', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000051'),
('208950000000052', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000052'),
('208950000000053', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000053'),
('208950000000054', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000054'),
('208950000000055', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000055'),
('208950000000056', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000056'),
('208950000000057', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000057'),
('208950000000058', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000058'),
('208950000000059', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000059'),
('208950000000060', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000060'),
('208950000000061', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000061'),
('208950000000062', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000062'),
('208950000000063', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000063'),
('208950000000064', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000064'),
('208950000000065', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000065'),
('208950000000066', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000066'),
('208950000000067', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000067'),
('208950000000068', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000068'),
('208950000000069', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000069'),
('208950000000070', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000070'),
('208950000000071', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000071'),
('208950000000072', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000072'),
('208950000000073', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000073'),
('208950000000074', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000074'),
('208950000000075', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000075'),
('208950000000076', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000076'),
('208950000000077', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000077'),
('208950000000078', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000078'),
('208950000000079', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000079'),
('208950000000080', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000080'),
('208950000000081', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000081'),
('208950000000082', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000082'),
('208950000000083', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000083'),
('208950000000084', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000084'),
('208950000000085', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000085'),
('208950000000086', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000086'),
('208950000000087', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000087'),
('208950000000088', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000088'),
('208950000000089', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000089'),
('208950000000090', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000090'),
('208950000000091', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000091'),
('208950000000092', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000092'),
('208950000000093', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000093'),
('208950000000094', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000094'),
('208950000000095', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000095'),
('208950000000096', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000096'),
('208950000000097', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000097'),
('208950000000098', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000098'),
('208950000000099', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000099'),

('208950000000110', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000110'),
('208950000000111', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000111'),
('208950000000112', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000112'),
('208950000000113', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000113'),
('208950000000214', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000214'),
('208950000000215', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000215'),
('208950000000216', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000216'),
('208950000000217', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000217'),
('208950000000318', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000318'),
('208950000000319', '5G_AKA', '0C0A34601D4F07677303652C0462535B', '0C0A34601D4F07677303652C0462535B', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000319');


-- ('208950000000132', '5G_AKA', '0C0A34601D4F07677303652C0462535B', 'fec86ba6eb707ed08905757b1bb44b8f', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000132'),
-- ('208950000000133', '5G_AKA', '0C0A34601D4F07677303652C0462535B', 'fec86ba6eb707ed08905757b1bb44b8f', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000133'),
-- ('208950000000134', '5G_AKA', '0C0A34601D4F07677303652C0462535B', 'fec86ba6eb707ed08905757b1bb44b8f', '{\"sqn\": \"000000000020\", \"sqnScheme\": \"NON_TIME_BASED\", \"lastIndexes\": {\"ausf\": 0}}', '8000', 'milenage', '63bfa50ee6523365ff14c1f45f88737d', NULL, NULL, NULL, NULL, '208950000000134');

-- --------------------------------------------------------

--
-- Table structure for table `SdmSubscriptions`
--

CREATE TABLE `SdmSubscriptions` (
  `ueid` varchar(15) NOT NULL,
  `subsId` int(10) UNSIGNED NOT NULL,
  `nfInstanceId` varchar(50) NOT NULL,
  `implicitUnsubscribe` tinyint(1) DEFAULT NULL,
  `expires` varchar(50) DEFAULT NULL,
  `callbackReference` varchar(50) NOT NULL,
  `amfServiceName` json DEFAULT NULL,
  `monitoredResourceUris` json NOT NULL,
  `singleNssai` json DEFAULT NULL,
  `dnn` varchar(50) DEFAULT NULL,
  `subscriptionId` varchar(50) DEFAULT NULL,
  `plmnId` json DEFAULT NULL,
  `immediateReport` tinyint(1) DEFAULT NULL,
  `report` json DEFAULT NULL,
  `supportedFeatures` varchar(50) DEFAULT NULL,
  `contextInfo` json DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Table structure for table `SessionManagementSubscriptionData`
--

CREATE TABLE `SessionManagementSubscriptionData` (
  `ueid` varchar(15) NOT NULL,
  `servingPlmnid` varchar(15) NOT NULL,
  `singleNssai` json NOT NULL,
  `dnnConfigurations` json DEFAULT NULL,
  `internalGroupIds` json DEFAULT NULL,
  `sharedVnGroupDataIds` json DEFAULT NULL,
  `sharedDnnConfigurationsId` varchar(50) DEFAULT NULL,
  `odbPacketServices` json DEFAULT NULL,
  `traceData` json DEFAULT NULL,
  `sharedTraceDataId` varchar(50) DEFAULT NULL,
  `expectedUeBehavioursList` json DEFAULT NULL,
  `suggestedPacketNumDlList` json DEFAULT NULL,
  `3gppChargingCharacteristics` varchar(50) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO `SessionManagementSubscriptionData` (`ueid`, `servingPlmnid`, `singleNssai`, `dnnConfigurations`) VALUES 
('208950000000031', '20895', '{\"sst\": 222, \"sd\": \"123\"}','{\"default\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 9,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"100Mbps\", \"downlink\":\"100Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"12.1.1.15\"}]}}'),
('208950000000032', '20895', '{\"sst\": 222, \"sd\": \"123\"}','{\"default\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 9,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"100Mbps\", \"downlink\":\"100Mbps\"}}}'),
('208950000000110', '20895', '{\"sst\": 1, \"sd\": \"000001\"}','{\"oai\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 9,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"1Mbps\", \"downlink\":\"2Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"12.1.1.2\"}]}}'),
('208950000000111', '20895', '{\"sst\": 1, \"sd\": \"000001\"}','{\"oai\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 9,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"1Mbps\", \"downlink\":\"2Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"12.1.1.3\"}]}}'),
('208950000000112', '20895', '{\"sst\": 1, \"sd\": \"000001\"}','{\"oai\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 9,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"1Mbps\", \"downlink\":\"2Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"12.1.1.4\"}]}}'),
('208950000000113', '20895', '{\"sst\": 1, \"sd\": \"000001\"}','{\"oai\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 9,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"1Mbps\", \"downlink\":\"2Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"12.1.1.5\"}]}}'),
('208950000000214', '20895', '{\"sst\": 2, \"sd\": \"000001\"}','{\"oai.2\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 86,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"10Mbps\", \"downlink\":\"10Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"13.1.1.2\"}]}}'),
('208950000000215', '20895', '{\"sst\": 2, \"sd\": \"000001\"}','{\"oai.2\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 86,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"10Mbps\", \"downlink\":\"10Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"13.1.1.3\"}]}}'),
('208950000000216', '20895', '{\"sst\": 2, \"sd\": \"000001\"}','{\"oai.2\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 86,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"10Mbps\", \"downlink\":\"10Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"13.1.1.4\"}]}}'),
('208950000000217', '20895', '{\"sst\": 2, \"sd\": \"000001\"}','{\"oai.2\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 86,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"10Mbps\", \"downlink\":\"10Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"13.1.1.5\"}]}}'),
('208950000000318', '20895', '{\"sst\": 3, \"sd\": \"000001\"}','{\"oai.3\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 76,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"20Mbps\", \"downlink\":\"10Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"14.1.1.2\"}]}}'),
('208950000000319', '20895', '{\"sst\": 3, \"sd\": \"000001\"}','{\"oai.3\":{\"pduSessionTypes\":{ \"defaultSessionType\": \"IPV4\"},\"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},\"5gQosProfile\": {\"5qi\": 76,\"arp\":{\"priorityLevel\": 1,\"preemptCap\": \"NOT_PREEMPT\",\"preemptVuln\":\"NOT_PREEMPTABLE\"},\"priorityLevel\":1},\"sessionAmbr\":{\"uplink\":\"20Mbps\", \"downlink\":\"10Mbps\"},\"staticIpAddress\":[{\"ipv4Addr\": \"14.1.1.3\"}]}}');


--
-- Table structure for table `SmfRegistrations`
--

CREATE TABLE `SmfRegistrations` (
  `ueid` varchar(15) NOT NULL,
  `subpduSessionId` int(10) NOT NULL,
  `smfInstanceId` varchar(50) NOT NULL,
  `smfSetId` varchar(50) DEFAULT NULL,
  `supportedFeatures` varchar(50) DEFAULT NULL,
  `pduSessionId` int(10) NOT NULL,
  `singleNssai` json NOT NULL,
  `dnn` varchar(50) DEFAULT NULL,
  `emergencyServices` tinyint(1) DEFAULT NULL,
  `pcscfRestorationCallbackUri` varchar(50) DEFAULT NULL,
  `plmnId` json NOT NULL,
  `pgwFqdn` varchar(50) DEFAULT NULL,
  `epdgInd` tinyint(1) DEFAULT NULL,
  `deregCallbackUri` varchar(50) DEFAULT NULL,
  `registrationReason` json DEFAULT NULL,
  `registrationTime` varchar(50) DEFAULT NULL,
  `contextInfo` json DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;


-- --------------------------------------------------------

--
-- Table structure for table `SmfSelectionSubscriptionData`
--

CREATE TABLE `SmfSelectionSubscriptionData` (
  `ueid` varchar(15) NOT NULL,
  `servingPlmnid` varchar(15) NOT NULL,
  `supportedFeatures` varchar(50) DEFAULT NULL,
  `subscribedSnssaiInfos` json DEFAULT NULL,
  `sharedSnssaiInfosId` varchar(50) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `AccessAndMobilitySubscriptionData`
--
ALTER TABLE `AccessAndMobilitySubscriptionData`
  ADD PRIMARY KEY (`ueid`,`servingPlmnid`) USING BTREE;

--
-- Indexes for table `Amf3GppAccessRegistration`
--
ALTER TABLE `Amf3GppAccessRegistration`
  ADD PRIMARY KEY (`ueid`);

--
-- Indexes for table `AuthenticationStatus`
--
ALTER TABLE `AuthenticationStatus`
  ADD PRIMARY KEY (`ueid`);

--
-- Indexes for table `AuthenticationSubscription`
--
ALTER TABLE `AuthenticationSubscription`
  ADD PRIMARY KEY (`ueid`);

--
-- Indexes for table `SdmSubscriptions`
--
ALTER TABLE `SdmSubscriptions`
  ADD PRIMARY KEY (`subsId`,`ueid`) USING BTREE;

--
-- Indexes for table `SessionManagementSubscriptionData`
--
ALTER TABLE `SessionManagementSubscriptionData`
  ADD PRIMARY KEY (`ueid`,`servingPlmnid`) USING BTREE;

--
-- Indexes for table `SmfRegistrations`
--
ALTER TABLE `SmfRegistrations`
  ADD PRIMARY KEY (`ueid`,`subpduSessionId`) USING BTREE;

--
-- Indexes for table `SmfSelectionSubscriptionData`
--
ALTER TABLE `SmfSelectionSubscriptionData`
  ADD PRIMARY KEY (`ueid`,`servingPlmnid`) USING BTREE;

--
-- AUTO_INCREMENT for dumped tables
--

-- ADD subscription information for bonus II

--
-- AUTO_INCREMENT for table `SdmSubscriptions`
--
ALTER TABLE `SdmSubscriptions`
  MODIFY `subsId` int(10) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;

-- ============================ PCF POLICY TABLES ==============================
USE oai_db;   -- belt-and-braces; session DB is still oai_db here

-- ---- DnnPolicyDecision (schema only; no DNN-level decisions in YAML) --------
DROP TABLE IF EXISTS `DnnPolicyDecision_PccRuleIds`;
DROP TABLE IF EXISTS `DnnPolicyDecision`;
CREATE TABLE `DnnPolicyDecision` (
  `Dnn` VARCHAR(128) NOT NULL PRIMARY KEY,
  `DnnIsSet` TINYINT(1) NOT NULL,
  `PccRuleIdsIsSet` TINYINT(1) NOT NULL) ENGINE=InnoDB;
CREATE TABLE `DnnPolicyDecision_PccRuleIds` (
  `object_id` VARCHAR(128) NOT NULL,
  `index` BIGINT UNSIGNED NOT NULL,
  `value` TEXT NOT NULL,
  CONSTRAINT `DnnPolicyDecision_PccRuleIds_object_id_fk`
    FOREIGN KEY (`object_id`) REFERENCES `DnnPolicyDecision` (`Dnn`)
    ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `DnnPolicyDecision_PccRuleIds` (`object_id`);
CREATE INDEX `index_i`     ON `DnnPolicyDecision_PccRuleIds` (`index`);

-- ---- SlicePolicyDecision (schema only; no slice-level decisions in YAML) ----
DROP TABLE IF EXISTS `SlicePolicyDecision_PccRuleIds`;
DROP TABLE IF EXISTS `SlicePolicyDecision`;
CREATE TABLE `SlicePolicyDecision` (
  `Snssai_Sst` INT NOT NULL,
  `Snssai_Sd` VARCHAR(128) NOT NULL,
  `Snssai_SdIsSet` TINYINT(1) NOT NULL,
  `SnssaiIsSet` TINYINT(1) NOT NULL,
  `PccRuleIdsIsSet` TINYINT(1) NOT NULL,
  PRIMARY KEY (`Snssai_Sst`,`Snssai_Sd`,`Snssai_SdIsSet`)) ENGINE=InnoDB;
CREATE TABLE `SlicePolicyDecision_PccRuleIds` (
  `object_id_Sst` INT NOT NULL,
  `object_id_Sd` VARCHAR(128) NOT NULL,
  `object_id_SdIsSet` TINYINT(1) NOT NULL,
  `index` BIGINT UNSIGNED NOT NULL,
  `value` TEXT NOT NULL,
  CONSTRAINT `SlicePolicyDecision_PccRuleIds_object_id_fk`
    FOREIGN KEY (`object_id_Sst`,`object_id_Sd`,`object_id_SdIsSet`)
    REFERENCES `SlicePolicyDecision` (`Snssai_Sst`,`Snssai_Sd`,`Snssai_SdIsSet`)
    ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `SlicePolicyDecision_PccRuleIds`
  (`object_id_Sst`,`object_id_Sd`,`object_id_SdIsSet`);
CREATE INDEX `index_i`     ON `SlicePolicyDecision_PccRuleIds` (`index`);

-- ---- QosData (schema only; no rule references refQosData) -------------------
DROP TABLE IF EXISTS `QosData`;
CREATE TABLE `QosData` (
  `QosId` VARCHAR(128) NOT NULL PRIMARY KEY,
  `r_5qi` INT NOT NULL, `r_5qiIsSet` TINYINT(1) NOT NULL,
  `MaxbrUl` TEXT NOT NULL, `MaxbrUlIsSet` TINYINT(1) NOT NULL,
  `MaxbrDl` TEXT NOT NULL, `MaxbrDlIsSet` TINYINT(1) NOT NULL,
  `GbrUl` TEXT NOT NULL, `GbrUlIsSet` TINYINT(1) NOT NULL,
  `GbrDl` TEXT NOT NULL, `GbrDlIsSet` TINYINT(1) NOT NULL,
  `Arp_PriorityLevel` INT NOT NULL,
  `Arp_PreemptCap_value_value` ENUM('INVALID_VALUE_OPENAPI_GENERATED','NOT_PREEMPT','MAY_PREEMPT') NOT NULL,
  `Arp_PreemptVuln_value_value` ENUM('INVALID_VALUE_OPENAPI_GENERATED','NOT_PREEMPTABLE','PREEMPTABLE') NOT NULL,
  `ArpIsSet` TINYINT(1) NOT NULL,
  `Qnc` TINYINT(1) NOT NULL, `QncIsSet` TINYINT(1) NOT NULL,
  `PriorityLevel` INT NOT NULL, `PriorityLevelIsSet` TINYINT(1) NOT NULL,
  `AverWindow` INT NOT NULL, `AverWindowIsSet` TINYINT(1) NOT NULL,
  `MaxDataBurstVol` INT NOT NULL, `MaxDataBurstVolIsSet` TINYINT(1) NOT NULL,
  `ReflectiveQos` TINYINT(1) NOT NULL, `ReflectiveQosIsSet` TINYINT(1) NOT NULL,
  `SharingKeyDl` TEXT NOT NULL, `SharingKeyDlIsSet` TINYINT(1) NOT NULL,
  `SharingKeyUl` TEXT NOT NULL, `SharingKeyUlIsSet` TINYINT(1) NOT NULL,
  `MaxPacketLossRateDl` INT NOT NULL, `MaxPacketLossRateDlIsSet` TINYINT(1) NOT NULL,
  `MaxPacketLossRateUl` INT NOT NULL, `MaxPacketLossRateUlIsSet` TINYINT(1) NOT NULL,
  `DefQosFlowIndication` TINYINT(1) NOT NULL, `DefQosFlowIndicationIsSet` TINYINT(1) NOT NULL,
  `ExtMaxDataBurstVol` INT NOT NULL, `ExtMaxDataBurstVolIsSet` TINYINT(1) NOT NULL,
  `PacketDelayBudget` INT NOT NULL, `PacketDelayBudgetIsSet` TINYINT(1) NOT NULL,
  `PacketErrorRate` TEXT NOT NULL, `PacketErrorRateIsSet` TINYINT(1) NOT NULL) ENGINE=InnoDB;

-- ---- TrafficControlDataODB (schema + traffic_rules.yaml seed) ---------------
DROP TABLE IF EXISTS `TrafficControlDataODB`;
CREATE TABLE `TrafficControlDataODB` (
  `TcId` VARCHAR(128) NOT NULL PRIMARY KEY,
  `FlowStatus` TEXT NOT NULL, `FlowStatusIsSet` TINYINT(1) NOT NULL,
  `RedirectInfo` TEXT NOT NULL, `RedirectInfoIsSet` TINYINT(1) NOT NULL,
  `AddRedirectInfo` TEXT NOT NULL, `AddRedirectInfoIsSet` TINYINT(1) NOT NULL,
  `MuteNotif` TINYINT(1) NOT NULL, `MuteNotifIsSet` TINYINT(1) NOT NULL,
  `TrafficSteeringPolIdDl` TEXT NOT NULL, `TrafficSteeringPolIdDlIsSet` TINYINT(1) NOT NULL,
  `TrafficSteeringPolIdUl` TEXT NOT NULL, `TrafficSteeringPolIdUlIsSet` TINYINT(1) NOT NULL,
  `RouteToLocs` TEXT NOT NULL, `RouteToLocsIsSet` TINYINT(1) NOT NULL,
  `TraffCorreInd` TINYINT(1) NOT NULL, `TraffCorreIndIsSet` TINYINT(1) NOT NULL,
  `UpPathChgEvent` TEXT NOT NULL, `UpPathChgEventIsSet` TINYINT(1) NOT NULL,
  `SteerFun` TEXT NOT NULL, `SteerFunIsSet` TINYINT(1) NOT NULL,
  `SteerModeDl` TEXT NOT NULL, `SteerModeDlIsSet` TINYINT(1) NOT NULL,
  `SteerModeUl` TEXT NOT NULL, `SteerModeUlIsSet` TINYINT(1) NOT NULL,
  `MulAccCtrl` TEXT NOT NULL, `MulAccCtrlIsSet` TINYINT(1) NOT NULL) ENGINE=InnoDB;

INSERT INTO `TrafficControlDataODB`
 (`TcId`,`FlowStatus`,`FlowStatusIsSet`,`RedirectInfo`,`RedirectInfoIsSet`,
  `AddRedirectInfo`,`AddRedirectInfoIsSet`,`MuteNotif`,`MuteNotifIsSet`,
  `TrafficSteeringPolIdDl`,`TrafficSteeringPolIdDlIsSet`,
  `TrafficSteeringPolIdUl`,`TrafficSteeringPolIdUlIsSet`,
  `RouteToLocs`,`RouteToLocsIsSet`,`TraffCorreInd`,`TraffCorreIndIsSet`,
  `UpPathChgEvent`,`UpPathChgEventIsSet`,`SteerFun`,`SteerFunIsSet`,
  `SteerModeDl`,`SteerModeDlIsSet`,`SteerModeUl`,`SteerModeUlIsSet`,
  `MulAccCtrl`,`MulAccCtrlIsSet`) VALUES
('steering-scenario-embb', '',0,'',0,'',0,0,0,'',0,'',0,'[{"dnai":"internet-embb"}]', 1,0,0,'',0,'',0,'',0,'',0,'',0),
('steering-scenario-urllc','',0,'',0,'',0,0,0,'',0,'',0,'[{"dnai":"internet-urllc"}]',1,0,0,'',0,'',0,'',0,'',0,'',0),
('steering-scenario-miot', '',0,'',0,'',0,0,0,'',0,'',0,'[{"dnai":"internet-miot"}]', 1,0,0,'',0,'',0,'',0,'',0,'',0);

-- ---- PccRuleODB (schema + pcc_rules.yaml seed) -----------------------------
DROP TABLE IF EXISTS `PccRuleODB_RefQosMon`;
DROP TABLE IF EXISTS `PccRuleODB_RefUmN3gData`;
DROP TABLE IF EXISTS `PccRuleODB_RefUmData`;
DROP TABLE IF EXISTS `PccRuleODB_RefChgN3gData`;
DROP TABLE IF EXISTS `PccRuleODB_RefChgData`;
DROP TABLE IF EXISTS `PccRuleODB_RefTcData`;
DROP TABLE IF EXISTS `PccRuleODB_RefAltQosParams`;
DROP TABLE IF EXISTS `PccRuleODB_RefQosData`;
DROP TABLE IF EXISTS `PccRuleODB`;
CREATE TABLE `PccRuleODB` (
  `FlowInfos` TEXT NOT NULL, `FlowInfosIsSet` TINYINT(1) NOT NULL,
  `AppId` TEXT NOT NULL, `AppIdIsSet` TINYINT(1) NOT NULL,
  `AppDescriptor` TEXT NOT NULL, `AppDescriptorIsSet` TINYINT(1) NOT NULL,
  `ContVer` INT NOT NULL, `ContVerIsSet` TINYINT(1) NOT NULL,
  `PccRuleId` VARCHAR(128) NOT NULL PRIMARY KEY,
  `Precedence` INT NOT NULL, `PrecedenceIsSet` TINYINT(1) NOT NULL,
  `AfSigProtocol` TEXT NOT NULL, `AfSigProtocolIsSet` TINYINT(1) NOT NULL,
  `AppReloc` TINYINT(1) NOT NULL, `AppRelocIsSet` TINYINT(1) NOT NULL,
  `RefQosDataIsSet` TINYINT(1) NOT NULL, `RefAltQosParamsIsSet` TINYINT(1) NOT NULL,
  `RefTcDataIsSet` TINYINT(1) NOT NULL, `RefChgDataIsSet` TINYINT(1) NOT NULL,
  `RefChgN3gDataIsSet` TINYINT(1) NOT NULL, `RefUmDataIsSet` TINYINT(1) NOT NULL,
  `RefUmN3gDataIsSet` TINYINT(1) NOT NULL,
  `RefCondData` TEXT NOT NULL, `RefCondDataIsSet` TINYINT(1) NOT NULL,
  `RefQosMonIsSet` TINYINT(1) NOT NULL,
  `AddrPreserInd` TINYINT(1) NOT NULL, `AddrPreserIndIsSet` TINYINT(1) NOT NULL,
  `TscaiInputDl` TEXT NOT NULL, `TscaiInputDlIsSet` TINYINT(1) NOT NULL,
  `TscaiInputUl` TEXT NOT NULL, `TscaiInputUlIsSet` TINYINT(1) NOT NULL,
  `DdNotifCtrl` TEXT NOT NULL, `DdNotifCtrlIsSet` TINYINT(1) NOT NULL,
  `DdNotifCtrl2` TEXT NOT NULL, `DdNotifCtrl2IsSet` TINYINT(1) NOT NULL,
  `DisUeNotif` TINYINT(1) NOT NULL, `DisUeNotifIsSet` TINYINT(1) NOT NULL) ENGINE=InnoDB;
CREATE TABLE `PccRuleODB_RefQosData`     (`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefQosData_object_id_fk`     FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefQosData` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefQosData` (`index`);
CREATE TABLE `PccRuleODB_RefAltQosParams`(`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefAltQosParams_object_id_fk`FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefAltQosParams` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefAltQosParams` (`index`);
CREATE TABLE `PccRuleODB_RefTcData`      (`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefTcData_object_id_fk`      FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefTcData` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefTcData` (`index`);
CREATE TABLE `PccRuleODB_RefChgData`     (`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefChgData_object_id_fk`     FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefChgData` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefChgData` (`index`);
CREATE TABLE `PccRuleODB_RefChgN3gData`  (`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefChgN3gData_object_id_fk`  FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefChgN3gData` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefChgN3gData` (`index`);
CREATE TABLE `PccRuleODB_RefUmData`      (`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefUmData_object_id_fk`      FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefUmData` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefUmData` (`index`);
CREATE TABLE `PccRuleODB_RefUmN3gData`   (`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefUmN3gData_object_id_fk`   FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefUmN3gData` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefUmN3gData` (`index`);
CREATE TABLE `PccRuleODB_RefQosMon`      (`object_id` VARCHAR(128) NOT NULL,`index` BIGINT UNSIGNED NOT NULL,`value` TEXT NOT NULL,CONSTRAINT `PccRuleODB_RefQosMon_object_id_fk`      FOREIGN KEY (`object_id`) REFERENCES `PccRuleODB` (`PccRuleId`) ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `PccRuleODB_RefQosMon` (`object_id`); CREATE INDEX `index_i` ON `PccRuleODB_RefQosMon` (`index`);

INSERT INTO `PccRuleODB`
 (`FlowInfos`,`FlowInfosIsSet`,`AppId`,`AppIdIsSet`,`AppDescriptor`,`AppDescriptorIsSet`,
  `ContVer`,`ContVerIsSet`,`PccRuleId`,`Precedence`,`PrecedenceIsSet`,
  `AfSigProtocol`,`AfSigProtocolIsSet`,`AppReloc`,`AppRelocIsSet`,
  `RefQosDataIsSet`,`RefAltQosParamsIsSet`,`RefTcDataIsSet`,`RefChgDataIsSet`,
  `RefChgN3gDataIsSet`,`RefUmDataIsSet`,`RefUmN3gDataIsSet`,
  `RefCondData`,`RefCondDataIsSet`,`RefQosMonIsSet`,
  `AddrPreserInd`,`AddrPreserIndIsSet`,`TscaiInputDl`,`TscaiInputDlIsSet`,
  `TscaiInputUl`,`TscaiInputUlIsSet`,`DdNotifCtrl`,`DdNotifCtrlIsSet`,
  `DdNotifCtrl2`,`DdNotifCtrl2IsSet`,`DisUeNotif`,`DisUeNotifIsSet`) VALUES
('[{"flowDescription":"permit out ip from any to assigned"}]',1,'',0,'',0,0,0,'rule-embb', 10,1,'',0,0,0,0,0,1,0,0,0,0,'',0,0,0,0,'',0,'',0,'',0,'',0,0,0),
('[{"flowDescription":"permit out ip from any to assigned"}]',1,'',0,'',0,0,0,'rule-urllc',10,1,'',0,0,0,0,0,1,0,0,0,0,'',0,0,0,0,'',0,'',0,'',0,'',0,0,0),
('[{"flowDescription":"permit out ip from any to assigned"}]',1,'',0,'',0,0,0,'rule-miot', 10,1,'',0,0,0,0,0,1,0,0,0,0,'',0,0,0,0,'',0,'',0,'',0,'',0,0,0);

INSERT INTO `PccRuleODB_RefTcData` (`object_id`,`index`,`value`) VALUES
('rule-embb', 0,'steering-scenario-embb'),
('rule-urllc',0,'steering-scenario-urllc'),
('rule-miot', 0,'steering-scenario-miot');

-- ---- SupiPolicyDecision (schema + policy_decisions.yaml seed) ---------------
DROP TABLE IF EXISTS `SupiPolicyDecision_PccRuleIds`;
DROP TABLE IF EXISTS `SupiPolicyDecision`;
CREATE TABLE `SupiPolicyDecision` (
  `Supi` VARCHAR(128) NOT NULL PRIMARY KEY,
  `SupiIsSet` TINYINT(1) NOT NULL,
  `PccRuleIdsIsSet` TINYINT(1) NOT NULL) ENGINE=InnoDB;
CREATE TABLE `SupiPolicyDecision_PccRuleIds` (
  `object_id` VARCHAR(128) NOT NULL,
  `index` BIGINT UNSIGNED NOT NULL,
  `value` TEXT NOT NULL,
  CONSTRAINT `SupiPolicyDecision_PccRuleIds_object_id_fk`
    FOREIGN KEY (`object_id`) REFERENCES `SupiPolicyDecision` (`Supi`)
    ON DELETE CASCADE) ENGINE=InnoDB;
CREATE INDEX `object_id_i` ON `SupiPolicyDecision_PccRuleIds` (`object_id`);
CREATE INDEX `index_i`     ON `SupiPolicyDecision_PccRuleIds` (`index`);

INSERT INTO `SupiPolicyDecision` (`Supi`,`SupiIsSet`,`PccRuleIdsIsSet`) VALUES
('208950000000110',1,1),('208950000000111',1,1),('208950000000112',1,1),('208950000000113',1,1),
('208950000000214',1,1),('208950000000215',1,1),('208950000000216',1,1),('208950000000217',1,1),
('208950000000318',1,1),('208950000000319',1,1);

INSERT INTO `SupiPolicyDecision_PccRuleIds` (`object_id`,`index`,`value`) VALUES
('208950000000110',0,'rule-embb'), ('208950000000111',0,'rule-embb'),
('208950000000112',0,'rule-embb'), ('208950000000113',0,'rule-embb'),
('208950000000214',0,'rule-urllc'),('208950000000215',0,'rule-urllc'),
('208950000000216',0,'rule-urllc'),('208950000000217',0,'rule-urllc'),
('208950000000318',0,'rule-miot'), ('208950000000319',0,'rule-miot');

-- ============================ USER (MySQL 8 fix) ============================
CREATE USER 'test'@'%' IDENTIFIED WITH mysql_native_password BY 'test';
GRANT ALL PRIVILEGES ON *.* TO 'test'@'%';
FLUSH PRIVILEGES;
