/*********************************************
Description: CPU Custom module for the Inspector
			 Collect CPU % and report when % over 75%, 75% can be configured by changing the default parameter value @CPUThreshold in 
			 procedure [Inspector].[CPUReport]
Author: Adrian Buckman
Revision date: 04/12/2019

� www.sqlundercover.com 

MIT License
------------
 
Copyright 2019 Sql Undercover
 
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:
 
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

*********************************************/

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

IF SCHEMA_ID(N'Inspector') IS NOT NULL
BEGIN 

IF OBJECT_ID('Inspector.CPU',N'U') IS NULL 
BEGIN 
	CREATE TABLE [Inspector].[CPU] (
	Servername NVARCHAR(128),
	Log_Date DATETIME,
	EventTime DATETIME,
	SystemCPUUtilization INT,
	SQLCPUUtilization INT,
	OtherCPU AS SystemCPUUtilization-SQLCPUUtilization
	);
END


IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE [object_id] = OBJECT_ID('Inspector.CPU',N'U') AND [name] = N'CIX_CPU_EventTime')
BEGIN 
	CREATE CLUSTERED INDEX [CIX_CPU_EventTime] ON [Inspector].[CPU] (EventTime ASC);
END

IF NOT EXISTS(SELECT 1 FROM [Inspector].[Settings] WHERE [Description] = 'CPUHistoryRetentionInDays')
BEGIN 
	INSERT INTO [Inspector].[Settings] ([Description],[Value])
	VALUES('CPUHistoryRetentionInDays','7');
END



IF OBJECT_ID('Inspector.CPUInsert',N'P') IS NULL 
BEGIN 
EXEC('CREATE PROCEDURE [Inspector].[CPUInsert]
AS
BEGIN 
--Revision date: 04/12/2019
	DECLARE @ts_now BIGINT
	DECLARE @Frequency INT 
	DECLARE @CPUHistoryRetentionInDays INT 
	
	SET @CPUHistoryRetentionInDays = (SELECT ISNULL(TRY_CAST([Value] AS INT),7) FROM [Inspector].[Settings] WHERE [Description] = ''CPUHistoryRetentionInDays'');
	SET @Frequency = (SELECT Frequency FROM Inspector.Modules WHERE Modulename = ''CPU'' AND ModuleConfig_Desc = ''Default'');
	SET @ts_now = (SELECT cpu_ticks / (cpu_ticks/ms_ticks)  FROM sys.dm_os_sys_info);

	IF @CPUHistoryRetentionInDays IS NULL BEGIN SET @CPUHistoryRetentionInDays = 7 END;

	DELETE FROM [Inspector].[CPU] 
	WHERE [EventTime] < DATEADD(DAY,-@CPUHistoryRetentionInDays,GETDATE());
	
	INSERT INTO [Inspector].[CPU] (Servername,Log_Date,EventTime,SystemCPUUtilization,SQLCPUUtilization)
	SELECT 
	@@SERVERNAME,
	GETDATE(),
	EventTime, 
	COALESCE(system_cpu_utilization_post_sp2, system_cpu_utilization_pre_sp2) AS SystemCPUUtilization,
	COALESCE(sql_cpu_utilization_post_sp2, sql_cpu_utilization_pre_sp2) AS SQLCPUUtilization
	FROM 
	(
	  SELECT 
	    record.value(''(Record/@id)[1]'', ''int'') AS record_id,
	    DATEADD (ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS EventTime,
	    100-record.value(''(Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]'', ''int'') AS system_cpu_utilization_post_sp2,
	    record.value(''(Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]'', ''int'') AS sql_cpu_utilization_post_sp2 , 
	    100-record.value(''(Record/SchedluerMonitorEvent/SystemHealth/SystemIdle)[1]'', ''int'') AS system_cpu_utilization_pre_sp2,
	    record.value(''(Record/SchedluerMonitorEvent/SystemHealth/ProcessUtilization)[1]'', ''int'') AS sql_cpu_utilization_pre_sp2
	  FROM (
	    SELECT timestamp, CONVERT (xml, record) AS record 
	    FROM sys.dm_os_ring_buffers 
	    WHERE ring_buffer_type = ''RING_BUFFER_SCHEDULER_MONITOR''
	    AND record LIKE ''%<SystemHealth>%'') AS t
	) AS t
	WHERE EventTime > DATEADD(MINUTE,-@Frequency,GETDATE())
	AND NOT EXISTS (SELECT 1 FROM Inspector.CPU WHERE CPU.EventTime  = t.EventTime);
END');
END





IF OBJECT_ID('Inspector.CPUReport',N'P') IS NULL 
BEGIN 
EXEC('CREATE PROCEDURE [Inspector].[CPUReport] (
@Servername NVARCHAR(128),
@Modulename VARCHAR(50),
@TableHeaderColour VARCHAR(7) = ''#E6E6FA'',
@WarningHighlight VARCHAR(7),
@AdvisoryHighlight VARCHAR(7),
@InfoHighlight VARCHAR(7),
@ModuleConfig VARCHAR(20),
@WarningLevel TINYINT,
@ServerSpecific BIT,
@NoClutter BIT,
@TableTail VARCHAR(256),
@HtmlOutput VARCHAR(MAX) OUTPUT,
@CollectionOutOfDate BIT OUTPUT,
@PSCollection BIT,
@Debug BIT = 0,
@CPUThreshold INT = 75
)
AS

--Revision date: 04/12/2019
BEGIN
--Excluded from Warning level control
	DECLARE @HtmlTableHead VARCHAR(4000);
	DECLARE @Columnnames VARCHAR(2000);
	DECLARE @SQLtext NVARCHAR(4000);

	SET @Debug = [Inspector].[GetDebugFlag](@Debug,@ModuleConfig,@Modulename);


/********************************************************/
	--Your query MUST have a case statement that determines which colour to highlight rows
	--Your query MUST use an INTO clause to populate the temp table so that the column names can be determined for the report
	--@bgcolor is used the for table highlighting , Warning,Advisory and Info highlighting colours are determined from 
	--the ModuleWarningLevel table and your Case expression And/or Where clause will determine which rows get the highlight
	--query example:

SELECT 
CASE 
	WHEN SystemCPUUtilization >= @CPUThreshold+15 THEN @WarningHighlight
	WHEN SystemCPUUtilization > @CPUThreshold+10 AND SystemCPUUtilization < @CPUThreshold+15 THEN @AdvisoryHighlight
	WHEN SystemCPUUtilization > @CPUThreshold AND SystemCPUUtilization < @CPUThreshold+10 THEN @InfoHighlight
END AS [@bgcolor],
Servername,
CONVERT(VARCHAR(21),EventTime,113) AS EventTime,
SystemCPUUtilization,
SQLCPUUtilization,
OtherCPU
INTO #InspectorModuleReport
FROM [Inspector].[CPU]
WHERE SystemCPUUtilization > @CPUThreshold
AND EventTime > DATEADD(HOUR,-12,GETDATE())
ORDER BY EventTime ASC 

/********************************************************/

	SET @Columnnames = (
	SELECT 
	STUFF(Columnnames,1,1,'''') 
	FROM
	(
		SELECT '',''+name
		FROM tempdb.sys.all_columns
		WHERE [object_id] = OBJECT_ID(N''tempdb.dbo.#InspectorModuleReport'')
		AND name != N''@bgcolor''
		ORDER BY column_id ASC
		FOR XML PATH('''')
	) as g (Columnnames)
	);

	--Set columns names for the Html table
	SET @HtmlTableHead = (SELECT [Inspector].[GenerateHtmlTableheader] (
	@Servername,
	@Modulename,
	@ServerSpecific,
	''CPU greater than ''+CAST(@CPUThreshold AS VARCHAR(3))+''%'', --Title for the HTML table, you can use a string here instead such as ''My table title here'' if you want to
	@TableHeaderColour,
	@Columnnames)
	);


	SET @SQLtext = N''
	SELECT @HtmlOutput =
	(SELECT ''
	+''[@bgcolor],''
	+REPLACE(@Columnnames,'','','' AS ''''td'''','''''''',+ '') + '' AS ''''td'''','''''''''' 
	+'' FROM #InspectorModuleReport
	FOR XML PATH(''''tr''''),Elements);''
	--Add an ORDER BY if required

	EXEC sp_executesql @SQLtext,N''@HtmlOutput VARCHAR(MAX) OUTPUT'',@HtmlOutput = @HtmlOutput OUTPUT;

	--Optional
	--If in the above query you populate the table with something like ''No issues present'' then you probably do not want that to 
	--show when @Noclutter mode is on
	IF (@NoClutter = 1)
	BEGIN 
		IF(@HtmlOutput LIKE ''%<Your No issues present text here>%'')
		BEGIN
			SET @HtmlOutput = NULL;
		END
	END

	--If there is data for the HTML table then build the HTML table
	IF (@HtmlOutput IS NOT NULL)
	BEGIN 
		SET @HtmlOutput = 
			@HtmlTableHead
			+ @HtmlOutput
			+ @TableTail
			+''<p><BR><p>'';
	END


IF (@Debug = 1)
BEGIN 
	SELECT 
	OBJECT_NAME(@@PROCID) AS ''Procname'',
	@Servername AS ''@Servername'',
	@Modulename AS ''@Modulename'',
	@TableHeaderColour AS ''@TableHeaderColour'',
	@WarningHighlight AS ''@WarningHighlight'',
	@AdvisoryHighlight AS ''@AdvisoryHighlight'',
	@InfoHighlight AS ''@InfoHighlight'',
	@ModuleConfig AS ''@ModuleConfig'',
	@WarningLevel AS ''@WarningLevel'',
	@NoClutter AS ''@NoClutter'',
	@TableTail AS ''@TableTail'',
	@HtmlOutput AS ''@HtmlOutput'',
	@HtmlTableHead AS ''@HtmlTableHead'',
	@SQLtext AS ''@SQLtext'',
	@CollectionOutOfDate AS ''@CollectionOutOfDate'',
	@PSCollection AS ''@PSCollection''
END 

END')
END



IF NOT EXISTS(SELECT 1 FROM [Inspector].[Modules] WHERE [Modulename] = 'CPU')
BEGIN 
	INSERT INTO [Inspector].[Modules] ([ModuleConfig_Desc], [Modulename], [CollectionProcedurename], [ReportProcedurename], [ReportOrder], [WarningLevel], [ServerSpecific], [Debug], [IsActive], [HeaderText], [Frequency], [StartTime], [EndTime])
	VALUES('Default','CPU','CPUInsert','CPUReport',5,2,1,0,1,'CPU has exceeded your threshold',2,'00:00','23:59');
END



IF NOT EXISTS(SELECT 1 FROM [Inspector].[MultiWarningModules] WHERE [Modulename] IN ('CPU'))
BEGIN 
	INSERT INTO [Inspector].[MultiWarningModules] ([Modulename])
	VALUES('CPU');
END

END
ELSE 
BEGIN 
	RAISERROR('Inspector schema not found, ensure that the Inspector is installed then try running this script again',11,0);
END


/*
SELECT 
CASE 
	WHEN SystemCPUUtilization >= 90 THEN 'RED'
	WHEN SystemCPUUtilization > 80 AND SystemCPUUtilization < 90 THEN 'YELLOW'
	WHEN SystemCPUUtilization > 75 AND SystemCPUUtilization < 80 THEN 'WHITE'
END AS [@BGColor],
Servername,
CONVERT(VARCHAR(21),EventTime,113) AS EventTime,
SystemCPUUtilization,
SQLCPUUtilization,
OtherCPU
FROM [Inspector].[CPU]
WHERE SystemCPUUtilization > 75
ORDER BY EventTime ASC 
*/