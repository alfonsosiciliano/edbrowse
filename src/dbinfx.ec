/*********************************************************************
dbinfx.ec: C-level interface to SQL.
This is a layer above esql/c,
since embedded SQL is often difficult to use, especially for new programmers.
Most SQL queries are relatively simple, whence the esql API is overkill.
Why mess with cryptic $directives when you can write:
sql_select("select this, that from table1, table2 where keycolumn = %d",
27, &this, &that);

More important, this API automatically aborts (or longjumps) if an error
occurs, unless that error has been specifically trapped by the program.
This minimizes application-level error-leg programming,
thereby reducing the code by as much as 1/3.
To accomplish this, the errorPrint() function,
supplied by the application, must never return.
We assume it passes the error message
to stderr and to a logfile,
and then exits, or longjumps to a recovery point.

Note that this API works within the context of our own C programming
environment.

Note that dbapi.h does NOT include the Informix header files.
That would violate the spirit of this layer,
which attempts to sheild the application from the details of the SQL API.
If the application needed to see anything in the Informix header files,
we would be doing something wrong.
*********************************************************************/

/* bring in the necessary Informix headers */
$include sqlca;
$include sqltypes;
$include sqlda;
$include locator;

#include "eb.h"
#include "dbapi.h"

#define CACHELIMIT 10000 /* number of cached lines */

#define ENGINE_ERRCODE sqlca.sqlcode


/*********************************************************************
The status variable ENGINE_ERRCODE holds the return code from an Informix call.
This is then used by the function errorTrap() below.
If ENGINE_ERRCODE != 0, errorTrap() aborts the program, or performs
a recovery longjmp, as directed by the generic error function errorPrint().
errorTrap() returns true if an SQL error occurred, but that error
was trapped by the application.
In this case the calling routine should clean up as best it can and return.
*********************************************************************/

static const char *stmt_text = 0; /* text of the SQL statement */
static const short *exclist; /* list of error codes trapped by the application */
static short translevel;
static bool badtrans;

/* Through globals, make error info available to the application. */
int rv_lastStatus, rv_vendorStatus, rv_stmtOffset;
char *rv_badToken;

static void debugStatement(void)
{
	if(sql_debug && stmt_text)
		appendFileNF(sql_debuglog, stmt_text);
} /* debugStatement */

static void debugExtra(const char *s)
{
	if(sql_debug)
		appendFileNF(sql_debuglog, s);
} /* debugExtra */

/* Append the SQL statement to the debug log.  This is not strictly necessary
 * if sql_debug is set, since the statement has already been appended. */
static void showStatement(void)
{
	if(!sql_debug && stmt_text)
		appendFileNF(sql_debuglog, stmt_text);
} /* showStatement */

/* application sets the exception list */
void sql_exclist(const short *list) { exclist = list; }

void sql_exception(int errnum)
{
	static short list[2];
	list[0] = errnum;
	exclist = list;
} /* sql_exception */

/* text descriptions corresponding to our generic SQL error codes */
static char *sqlErrorList[] = {0,
	"miscelaneous SQL error",
	"syntax error in SQL statement",
	"filename cannot be used by SQL",
	"cannot convert/compare the columns/constants in the SQL statement",
	"bad string subscripting",
	"bad use of the rowid construct",
	"bad use of a blob column",
	"bad use of aggregate operators or columns",
	"bad use of a view",
	"bad use of a serial column",
	"bad use of a temp table",
	"operation cannot cross databases",
	"database is fucked up",
	"query interrupted by user",
	"could not connect to the database",
	"database has not yet been selected",
	"table not found",
	"duplicate table",
	"ambiguous table",
	"column not found",
	"duplicate column",
	"ambiguous column",
	"index not found",
	"duplicate index",
	"constraint not found",
	"duplicate constraint",
	"stored procedure not found",
	"duplicate stored procedure",
	"synonym not found",
	"duplicate synonym",
	"table has no primary or unique key",
	"duplicate primary or unique key",
	"cursor not specified, or cursor is not available",
	"duplicate cursor",
	"the database lacks the resources needed to complete this query",
	"check constrain violated",
	"referential integrity violated",
	"cannot manage or complete the transaction",
	"long transaction, too much log data generated",
	"this operation must be run inside a transaction",
	"cannot open, read, write, close, or otherwise manage a blob",
	"row, table, page, or database is already locked, or cannot be locked",
	"inserting null into a not null column",
	"no permission to modify the database in this way",
	"no current row established",
	"many rows were found where one was expected",
	"cannot union these select statements together",
	"cannot access or write the audit trail",
	"could not run SQL or gather data from a remote host",
	"where clause is semantically unmanageable",
	"deadlock detected",
0};

/* map Informix errors to our own exception codes, as defined in c_sql.h. */
static struct ERRORMAP {
	short infcode;
	short excno;
} errormap[] = {
	{200, EXCSYNTAX},
	{201, EXCSYNTAX},
	{202, EXCSYNTAX},
	{203, EXCSYNTAX},
	{204, EXCSYNTAX},
	{205, EXCROWIDUSE},
	{206, EXCNOTABLE},
	/* 207 */
	{208, EXCRESOURCE},
	{209, EXCDBCORRUPT},
	{210, EXCFILENAME},
	{211, EXCDBCORRUPT},
	{212, EXCRESOURCE},
	{213, EXCINTERRUPT},
	{214, EXCDBCORRUPT},
	{215, EXCDBCORRUPT},
	{216, EXCDBCORRUPT},
	{217, EXCNOCOLUMN},
	{218, EXCNOSYNONYM},
	{219, EXCCONVERT},
	{220, EXCSYNTAX},
	{221, EXCRESOURCE},
	{222, EXCRESOURCE},
	{223, EXCAMBTABLE},
	{224, EXCRESOURCE},
	{225, EXCRESOURCE},
	{226, EXCRESOURCE},
	{227, EXCROWIDUSE},
	{228, EXCROWIDUSE},
	{229, EXCRESOURCE},
	{230, EXCDBCORRUPT},
	{231, EXCAGGREGATEUSE},
	{232, EXCSERIAL},
	{233, EXCITEMLOCK},
	{234, EXCAMBCOLUMN},
	{235, EXCCONVERT},
	{236, EXCSYNTAX},
	{237, EXCMANAGETRANS},
	{238, EXCMANAGETRANS},
	{239, EXCDUPKEY},
	{240, EXCDBCORRUPT},
	{241, EXCMANAGETRANS},
	{249, EXCAMBCOLUMN},
	{250, EXCDBCORRUPT},
	{251, EXCSYNTAX},
	{252, EXCITEMLOCK},
	{253, EXCSYNTAX},
	{255, EXCNOTINTRANS},
	{256, EXCMANAGETRANS},
	{257, EXCRESOURCE},
	{258, EXCDBCORRUPT},
	{259, EXCNOCURSOR},
	{260, EXCNOCURSOR},
	{261, EXCRESOURCE},
	{262, EXCNOCURSOR},
	{263, EXCRESOURCE},
	{264, EXCRESOURCE},
	{265, EXCNOTINTRANS},
	{266, EXCNOCURSOR},
	{267, EXCNOCURSOR},
	{268, EXCDUPKEY},
	{269, EXCNOTNULLCOLUMN},
	{270, EXCDBCORRUPT},
	{271, EXCDBCORRUPT},
	{272, EXCPERMISSION},
	{273, EXCPERMISSION},
	{274, EXCPERMISSION},
	{275, EXCPERMISSION},
	{276, EXCNOCURSOR},
	{277, EXCNOCURSOR},
	{278, EXCRESOURCE},
	{281, EXCTEMPTABLEUSE},
	{282, EXCSYNTAX},
	{283, EXCSYNTAX},
	{284, EXCMANYROW},
	{285, EXCNOCURSOR},
	{286, EXCNOTNULLCOLUMN},
	{287, EXCSERIAL},
	{288, EXCITEMLOCK},
	{289, EXCITEMLOCK},
	{290, EXCNOCURSOR},
	{292, EXCNOTNULLCOLUMN},
	{293, EXCSYNTAX},
	{294, EXCAGGREGATEUSE},
	{295, EXCCROSSDB},
	{296, EXCNOTABLE},
	{297, EXCNOKEY},
	{298, EXCPERMISSION},
	{299, EXCPERMISSION},
	{300, EXCRESOURCE},
	{301, EXCRESOURCE},
	{302, EXCPERMISSION},
	{ 303, EXCAGGREGATEUSE},
	{304, EXCAGGREGATEUSE},
	{305, EXCSUBSCRIPT},
	{306, EXCSUBSCRIPT},
	{307, EXCSUBSCRIPT},
	{308, EXCCONVERT},
	{309, EXCAMBCOLUMN},
	{310, EXCDUPTABLE},
	{311, EXCDBCORRUPT},
	{312, EXCDBCORRUPT},
	{313, EXCPERMISSION},
	{314, EXCDUPTABLE},
	{315, EXCPERMISSION},
	{316, EXCDUPINDEX},
	{317, EXCUNION},
	{318, EXCFILENAME},
	{319, EXCNOINDEX},
	{320, EXCPERMISSION},
	{321, EXCAGGREGATEUSE},
	{323, EXCTEMPTABLEUSE},
	{324, EXCAMBCOLUMN},
	{325, EXCFILENAME},
	{326, EXCRESOURCE},
	{327, EXCITEMLOCK},
	{328, EXCDUPCOLUMN},
	{329, EXCNOCONNECT},
	{330, EXCRESOURCE},
	{331, EXCDBCORRUPT},
	{332, EXCTRACE},
	{333, EXCTRACE},
	{334, EXCTRACE},
	{335, EXCTRACE},
	{336, EXCTEMPTABLEUSE},
	{337, EXCTEMPTABLEUSE},
	{338, EXCTRACE},
	{339, EXCFILENAME},
	{340, EXCTRACE},
	{341, EXCTRACE},
	{342, EXCREMOTE},
	{343, EXCTRACE},
	{344, EXCTRACE},
	{345, EXCTRACE},
	{346, EXCDBCORRUPT},
	{347, EXCITEMLOCK},
	{348, EXCDBCORRUPT},
	{349, EXCNODB},
	{350, EXCDUPINDEX},
	{352, EXCNOCOLUMN},
	{353, EXCNOTABLE},
	{354, EXCSYNTAX},
	{355, EXCDBCORRUPT},
	{356, EXCCONVERT},
	{361, EXCRESOURCE},
	{362, EXCSERIAL},
	{363, EXCNOCURSOR},
	{365, EXCNOCURSOR},
	{366, EXCCONVERT},
	{367, EXCAGGREGATEUSE},
	{368, EXCDBCORRUPT},
	{369, EXCSERIAL},
	{370, EXCAMBCOLUMN},
	{371, EXCDUPKEY},
	{372, EXCTRACE},
	{373, EXCFILENAME},
	{374, EXCSYNTAX},
	{375, EXCMANAGETRANS},
	{376, EXCMANAGETRANS},
	{377, EXCMANAGETRANS},
	{378, EXCITEMLOCK},
	{382, EXCSYNTAX},
	{383, EXCAGGREGATEUSE},
	{384, EXCVIEWUSE},
	{385, EXCCONVERT},
	{386, EXCNOTNULLCOLUMN},
	{387, EXCPERMISSION},
	{388, EXCPERMISSION},
	{389, EXCPERMISSION},
	{390, EXCDUPSYNONYM},
	{391, EXCNOTNULLCOLUMN},
	{392, EXCDBCORRUPT},
	{393, EXCWHERECLAUSE},
	{394, EXCNOTABLE},
	{395, EXCWHERECLAUSE},
	{396, EXCWHERECLAUSE},
	{397, EXCDBCORRUPT},
	{398, EXCNOTINTRANS},
	{399, EXCMANAGETRANS},
	{400, EXCNOCURSOR},
	{401, EXCNOCURSOR},
	{404, EXCNOCURSOR},
	{406, EXCRESOURCE},
	{407, EXCDBCORRUPT},
	{408, EXCDBCORRUPT},
	{409, EXCNOCONNECT},
	{410, EXCNOCURSOR},
	{413, EXCNOCURSOR},
	{414, EXCNOCURSOR},
	{415, EXCCONVERT},
	{417, EXCNOCURSOR},
	{420, EXCREMOTE},
	{421, EXCREMOTE},
	{422, EXCNOCURSOR},
	{423, EXCNOROW},
	{424, EXCDUPCURSOR},
	{425, EXCITEMLOCK},
	{430, EXCCONVERT},
	{431, EXCCONVERT},
	{432, EXCCONVERT},
	{433, EXCCONVERT},
	{434, EXCCONVERT},
	{439, EXCREMOTE},
	{451, EXCRESOURCE},
	{452, EXCRESOURCE},
	{453, EXCDBCORRUPT},
	{454, EXCDBCORRUPT},
	{455, EXCRESOURCE},
	{457, EXCREMOTE},
	{458, EXCLONGTRANS},
	{459, EXCREMOTE},
	{460, EXCRESOURCE},
	{465, EXCRESOURCE},
	{468, EXCNOCONNECT},
	{472, EXCCONVERT},
	{473, EXCCONVERT},
	{474, EXCCONVERT},
	{482, EXCNOCURSOR},
	{484, EXCFILENAME},
	{500, EXCDUPINDEX},
	{501, EXCDUPINDEX},
	{502, EXCNOINDEX},
	{503, EXCRESOURCE},
	{504, EXCVIEWUSE},
	{505, EXCSYNTAX},
	{506, EXCPERMISSION},
	{507, EXCNOCURSOR},
	{508, EXCTEMPTABLEUSE},
	{509, EXCTEMPTABLEUSE},
	{510, EXCTEMPTABLEUSE},
	{512, EXCPERMISSION},
	{514, EXCPERMISSION},
	{515, EXCNOCONSTRAINT},
	{517, EXCRESOURCE},
	{518, EXCNOCONSTRAINT},
	{519, EXCCONVERT},
	{521, EXCITEMLOCK},
	{522, EXCNOTABLE},
	{524, EXCNOTINTRANS},
	{525, EXCREFINT},
	{526, EXCNOCURSOR},
	{528, EXCRESOURCE},
	{529, EXCNOCONNECT},
	{530, EXCCHECK},
	{531, EXCDUPCOLUMN},
	{532, EXCTEMPTABLEUSE},
	{534, EXCITEMLOCK},
	{535, EXCMANAGETRANS},
	{536, EXCSYNTAX},
	{537, EXCNOCONSTRAINT},
	{538, EXCDUPCURSOR},
	{539, EXCRESOURCE},
	{540, EXCDBCORRUPT},
	{541, EXCPERMISSION},
	{543, EXCAMBCOLUMN},
	{543, EXCSYNTAX},
	{544, EXCAGGREGATEUSE},
	{545, EXCPERMISSION},
	{548, EXCTEMPTABLEUSE},
	{549, EXCNOCOLUMN},
	{550, EXCRESOURCE},
	{551, EXCRESOURCE},
	{554, EXCSYNTAX},
	{559, EXCDUPSYNONYM},
	{560, EXCDBCORRUPT},
	{561, EXCAGGREGATEUSE},
	{562, EXCCONVERT},
	{536, EXCITEMLOCK},
	{564, EXCRESOURCE},
	{565, EXCRESOURCE},
	{566, EXCRESOURCE},
	{567, EXCRESOURCE},
	{568, EXCCROSSDB},
	{569, EXCCROSSDB},
	{570, EXCCROSSDB},
	{571, EXCCROSSDB},
	{573, EXCMANAGETRANS},
	{574, EXCAMBCOLUMN},
	{576, EXCTEMPTABLEUSE},
	{577, EXCDUPCONSTRAINT},
	{578, EXCSYNTAX},
	{579, EXCPERMISSION},
	{580, EXCPERMISSION},
	{582, EXCMANAGETRANS},
	{583, EXCPERMISSION},
	{586, EXCDUPCURSOR},
	{589, EXCREMOTE},
	{590, EXCDBCORRUPT},
	{591, EXCCONVERT},
	{592, EXCNOTNULLCOLUMN},
	{593, EXCSERIAL},
	{594, EXCBLOBUSE},
	{595, EXCAGGREGATEUSE},
	{597, EXCDBCORRUPT},
	{598, EXCNOCURSOR},
	{599, EXCSYNTAX},
	{600, EXCMANAGEBLOB},
	{601, EXCMANAGEBLOB},
	{602, EXCMANAGEBLOB},
	{603, EXCMANAGEBLOB},
	{604, EXCMANAGEBLOB},
	{605, EXCMANAGEBLOB},
	{606, EXCMANAGEBLOB},
	{607, EXCSUBSCRIPT},
	{608, EXCCONVERT},
	{610, EXCBLOBUSE},
	{611, EXCBLOBUSE},
	{612, EXCBLOBUSE},
	{613, EXCBLOBUSE},
	{614, EXCBLOBUSE},
	{615, EXCBLOBUSE},
	{616, EXCBLOBUSE},
	{617, EXCBLOBUSE},
	{618, EXCMANAGEBLOB},
	{622, EXCNOINDEX},
	{623, EXCNOCONSTRAINT},
	{625, EXCDUPCONSTRAINT},
	{628, EXCMANAGETRANS},
	{629, EXCMANAGETRANS},
	{630, EXCMANAGETRANS},
	{631, EXCBLOBUSE},
	{635, EXCPERMISSION},
	{636, EXCRESOURCE},
	{638, EXCBLOBUSE},
	{639, EXCBLOBUSE},
	{640, EXCDBCORRUPT},
	{649, EXCFILENAME},
	{650, EXCRESOURCE},
	{651, EXCRESOURCE},
	/* I'm not about to map all possible compile/runtime SPL errors. */
	/* Here's a few. */
	{655, EXCSYNTAX},
	{667, EXCSYNTAX},
	{673, EXCDUPSPROC},
	{674, EXCNOSPROC},
	{678, EXCSUBSCRIPT},
	{681, EXCDUPCOLUMN},
	{686, EXCMANYROW},
	{690, EXCREFINT},
	{691, EXCREFINT},
	{692, EXCREFINT},
	{702, EXCITEMLOCK},
	{703, EXCNOTNULLCOLUMN},
	{704, EXCDUPCONSTRAINT},
	{706, EXCPERMISSION},
	{707, EXCBLOBUSE},
	{722, EXCRESOURCE},
	{958, EXCDUPTABLE},
	{1214, EXCCONVERT},
	{1262, EXCCONVERT},
	{1264, EXCCONVERT},
	{25553, EXCNOCONNECT},
	{25587, EXCNOCONNECT},
	{25588, EXCNOCONNECT},
	{25596, EXCNOCONNECT},
	{0, 0}
}; /* ends of list */

static int errTranslate(int code)
{
	struct ERRORMAP *e;

	for(e=errormap; e->infcode; ++e) {
		if(e->infcode == code)
			return e->excno;
	}
	return EXCSQLMISC;
} /* errTranslate */

static bool errorTrap(void)
{
short i;

rv_lastStatus = rv_vendorStatus = 0; /* innocent until proven guilty */
rv_stmtOffset = 0;
rv_badToken = 0;
if(ENGINE_ERRCODE >= 0) return false; /* no problem */

showStatement();
rv_vendorStatus = -ENGINE_ERRCODE;
rv_lastStatus = errTranslate(rv_vendorStatus);
rv_stmtOffset = sqlca.sqlerrd[4];
rv_badToken = sqlca.sqlerrm;
if(!rv_badToken[0]) rv_badToken = 0;

/* if the application didn't trap for this exception, blow up! */
if(exclist) {
for(i=0; exclist[i]; ++i) {
if(exclist[i] == rv_lastStatus) {
exclist = 0; /* we've spent that exception */
return true;
}
}
}

errorPrint("2SQL error %d, %s", rv_vendorStatus, sqlErrorList[rv_lastStatus]);
return true; /* make the compiler happy */
} /* errorTrap */


/*********************************************************************
The OCURS structure given below maintains an open SQL cursor.
A static array of these structures allows multiple cursors
to be opened simultaneously.
*********************************************************************/

static struct OCURS {
char sname[8]; /* statement name */
char cname[8]; /* cursor name */
struct sqlda *desc;
char rv_type[NUMRETS];
long rownum;
short alloc;
short cid; /* cursor ID */
char flag;
char numRets;
char **fl; /* array of fetched lines */
} ocurs[NUMCURSORS];

/* values for struct OCURS.flag */
#define CURSOR_NONE 0
#define CURSOR_PREPARED 1
#define CURSOR_OPENED 2

/* find a free cursor structure */
static struct OCURS *findNewCursor(void)
{
struct OCURS *o;
short i;
for(o=ocurs, i=0; i<NUMCURSORS; ++i, ++o) {
if(o->flag != CURSOR_NONE) continue;
sprintf(o->cname, "c%u", i);
sprintf(o->sname, "s%u", i);
o->cid = 6000+i;
return o;
}
errorPrint("2more than %d cursors opend concurrently", NUMCURSORS);
return 0; /* make the compiler happy */
} /* findNewCursor */

/* dereference an existing cursor */
static struct OCURS *findCursor(int cid)
{
struct OCURS *o;
if(cid < 6000 || cid >= 6000+NUMCURSORS)
errorPrint("2cursor number %d is out of range", cid);
cid -= 6000;
o = ocurs+cid;
if(o->flag == CURSOR_NONE)
errorPrint("2cursor %d is not currently active", cid);
rv_numRets = o->numRets;
memcpy(rv_type, o->rv_type, NUMRETS);
return o;
} /* findCursor */

/* part of the disconnect() procedure */
static void clearAllCursors(void)
{
	int i, j;
	struct OCURS *o;

	for(i=0, o=ocurs; i<NUMCURSORS; ++i, ++o) {
		if(o->flag == CURSOR_NONE) continue;
		o->flag = CURSOR_NONE;
o->rownum = 0;
		if(o->fl) {
			for(j=0; j<o->alloc; ++j)
				nzFree(o->fl[j]);
			nzFree(o->fl);
			o->fl = 0;
		}
	} /* loop over cursors */

	translevel = 0;
	badtrans = false;
} /* clearAllCursors */


/*********************************************************************
Connect and disconect to SQL databases.
*********************************************************************/

void sql_connect(const char *db, const char *login, const char *pw) 
{
$char *dblocal = (char*)db;
login = pw = 0; /* not used here, so make the compiler happy */
if(isnullstring(dblocal)) {
dblocal = getenv("DBNAME");
if(isnullstring(dblocal))
errorPrint("2sql_connect receives no database, check $DBNAME");
}

if(sql_database) {
	stmt_text = "disconnect";
	debugStatement();
$disconnect current;
clearAllCursors();
sql_database = 0;
}

	stmt_text = "connect";
	debugStatement();
$connect to :dblocal;
if(errorTrap()) return;
sql_database = dblocal;

/* set default lock mode and isolation level for transaction management */
stmt_text = "lock isolation";
debugStatement();
$ set lock mode to wait;
if(errorTrap()) {
abort:
sql_disconnect();
return;
}
$ set isolation to committed read;
if(errorTrap()) goto abort;
exclist = 0;
} /* sql_connect */

void sql_disconnect(void)
{
if(sql_database) {
	stmt_text = "disconnect";
	debugStatement();
$disconnect current;
clearAllCursors();
sql_database = 0;
}
exclist = 0;
} /* sql_disconnect */

/* make sure we're connected to a database */
static void checkConnect(void)
{
	if(!sql_database)
		errorPrint("2SQL command issued, but no database selected");
} /* checkConnect */


/*********************************************************************
Begin, commit, and abort transactions.
SQL does not permit nested transactions; this API does, to a limited degree.
An inner transaction cannot fail while an outer one succeeds;
that would require SQL support which is not forthcoming.
However, as long as all transactions succeed, or the outer most fails,
everything works properly.
The static variable transLevel holds the number of nested transactions.
*********************************************************************/

/* begin a transaction */
void sql_begTrans(void)
{
	rv_lastStatus = 0;
	checkConnect();
		stmt_text = "begin work";
		debugStatement();
	/* count the nesting level of transactions. */
	if(!translevel) {
		badtrans = false;
		$begin work;
		if(errorTrap()) return;
	}
	++translevel;
	exclist = 0;
} /* sql_begTrans */

/* end a transaction */
static void endTrans(bool commit)
{
	rv_lastStatus = 0;
	checkConnect();

	if(translevel == 0)
		errorPrint("2end transaction without a matching begTrans()");
	--translevel;

	if(commit) {
			stmt_text = "commit work";
			debugStatement();
		if(badtrans)
			errorPrint("2Cannot commit a transaction around an aborted transaction");
		if(translevel == 0) {
			$commit work;
			if(ENGINE_ERRCODE) ++translevel;
			errorTrap();
		}
	} else { /* success or failure */
			stmt_text = "rollback work";
			debugStatement();
		badtrans = true;
		if(!translevel) { /* bottom level */
			$rollback work;
			if(ENGINE_ERRCODE) --translevel;
			errorTrap();
			badtrans = false;
		}
	} /* success or failure */

	/* At this point I will make a bold assumption --
	 * that all cursors are declared with hold.
	 * Hence they remain valid after the transaction is closed,
	 * and we don't have to change any of the OCURS structures. */

	exclist = 0;
} /* endTrans */

void sql_commitWork(void) { endTrans(true); }
void sql_rollbackWork(void) { endTrans(false); }

void sql_deferConstraints(void)
{
	if(!translevel)
		errorPrint("2Cannot defer constraints unless inside a transaction");
	stmt_text = "defer constraints";
	debugStatement();
	$set constraints all deferred;
	errorTrap();
	exclist = 0;
} /* sql_deferConstraints */


/*********************************************************************
Blob management routines, a somewhat awkward interface.
Global variables tell SQL where to unload the next fetched blob:
either a file (truncate or append) or an allocated chunk of memory.
This assumes each fetch or select statement retrieves at most one blob.
Since there is no %blob directive in lineFormat(),
one cannot simply slip a blob in with the rest of the data as a row is
updated or inserted.  Instead the row must be created first,
then the blob is entered separately, using blobInsert().
This means every blob column must permit nulls, at least within the schema.
Also, what use to be an atomic insert might become a multi-statement
transaction if data integrity is important.
Future versions of our line formatting software may support a %blob directive,
which makes sense only when the formatted string is destined for SQL.
*********************************************************************/

/* information about the blob being fetched */
const char *rv_blobFile;
bool rv_blobAppend;
void *rv_blobLoc; /* location of blob in memory */
int rv_blobSize; /* size of blob in bytes */
static loc_t blobstruct; /* Informix structure to manage the blob */

/* insert a blob into the database */
void sql_blobInsert(const char *tabname, const char *colname, int rowid,
const char *filename, void *offset, int length)
{
$char blobcmd[100];
$loc_t insblob;

/* basic sanity checks */
checkConnect();
if(isnullstring(tabname)) errorPrint("2blobInsert, missing table name");
if(isnullstring(colname)) errorPrint("2blobInsert, missing column name");
if(rowid <= 0) errorPrint("2invalid rowid in blobInsert");
if(length < 0) errorPrint("2invalid length in blobInsert");
if(strlen(tabname) + strlen(colname) + 42 >= sizeof(blobcmd))
errorPrint("2internal blobInsert command too long");

/* set up the blob structure */
memset(&insblob, 0, sizeof(insblob));
if(!filename) {
insblob.loc_loctype = LOCMEMORY;
if(offset) {
if(length == 0) offset = 0;
}
if(!offset) length = -1;
insblob.loc_buffer = offset;
insblob.loc_bufsize = length;
insblob.loc_size = length;
if(!offset) insblob.loc_indicator = -1;
} else {
insblob.loc_loctype = LOCFNAME;
insblob.loc_fname = (char*)filename;
insblob.loc_oflags = LOC_RONLY;
insblob.loc_size = -1;
}

/* set up the blob insert command, using one host variable */
sprintf(blobcmd, "update %s set %s = ? where rowid = %d",
tabname, colname, rowid);
stmt_text = blobcmd;
debugStatement();
$prepare blobinsert from :blobcmd;
if(errorTrap()) return;
$execute blobinsert using :insblob;
errorTrap();
rv_lastNrows = sqlca.sqlerrd[2];
rv_lastRowid = sqlca.sqlerrd[5];
if(sql_debug) appendFile(sql_debuglog, "%d rows affected", rv_lastNrows);
exclist = 0;
} /* sql_blobInsert */


/*********************************************************************
When an SQL statement is prepared, the engine tells us the types and lengths
of the columns.  Use this information to "normalize" the sqlda
structure, so that columns are fetched using our preferred formats.
For instance, smallints and ints both map into int variables,
varchars become chars, dates map into strings (so that we can convert
them into our own vendor-independent binary representations later), etc.
We assume the number and types of returns have been established.
Once retsSetup has "normalized" the sqlda structure,
run the select or fetch, and then call retsCleanup to post-process the data.
This will, for example, turn dates, fetched into strings,
into our own 4-byte representations.
The same for time intervals, money, etc.
*********************************************************************/

/* Arrays that hold the return values from a select statement. */
int rv_numRets; /* number of returned values */
char rv_type[NUMRETS+1]; /* datatypes of returned values */
char rv_name[NUMRETS+1][COLNAMELEN]; /* column names */
LF  rv_data[NUMRETS]; /* the returned values */
int rv_lastNrows, rv_lastRowid, rv_lastSerial;
/* Temp area to read the Informix values, as strings */
static char retstring[NUMRETS][STRINGLEN+4];
static va_list sqlargs;

static void retsSetup(struct sqlda *desc)
{
short i;
bool blobpresent = false;
struct sqlvar_struct   *v;

for(i=0; (unsigned)i< NUMRETS; ++i) {
rv_data[i].l = nullint;
retstring[i][0] = 0;
rv_name[i][0] = 0;
}
if(!desc) return;

  for(i=0,v=desc->sqlvar; i<rv_numRets; ++i,++v ) {
strncpy(rv_name[i], v->sqlname, COLNAMELEN);
switch(rv_type[i]) {
case 'S':
case 'C':
case 'D':
case 'I':
v->sqltype = CCHARTYPE;
v->sqllen = STRINGLEN+2;
v->sqldata = retstring[i];
rv_data[i].ptr = retstring[i];
break;

case 'N':
v->sqltype = CINTTYPE;
v->sqllen = 4;
v->sqldata =  (char *) &rv_data[i].l;
break;

case 'F':
case 'M':
v->sqltype = CDOUBLETYPE;
v->sqllen = 8;
v->sqldata = (char*) &rv_data[i].f;
rv_data[i].f = nullfloat;
break;

case 'B':
case 'T':
if(blobpresent)
errorPrint("2Cannot select more than one blob at a time");
blobpresent = true;
v->sqltype = CLOCATORTYPE;
v->sqllen = sizeof(blobstruct);
v->sqldata = (char*) &blobstruct;
memset(&blobstruct, 0, sizeof(blobstruct));
if(!rv_blobFile) {
blobstruct.loc_loctype = LOCMEMORY;
blobstruct.loc_mflags = LOC_ALLOC;
blobstruct.loc_bufsize = -1;
} else {
blobstruct.loc_loctype = LOCFNAME;
blobstruct.loc_fname = (char*)rv_blobFile;
blobstruct.lc_union.lc_file.lc_mode = 0600;
blobstruct.loc_oflags =
(rv_blobAppend ? LOC_WONLY|LOC_APPEND : LOC_WONLY);
}
break;

default:
errorPrint("@bad character %c in retsSetup", rv_type[i]);
} /* switch */
} /* loop over fetched columns */
} /* retsSetup */

/* clean up fetched values, eg. convert date to our proprietary format. */
static void retsCleanup(void)
{
short i, l;
bool yearfirst;

/* no blobs unless proven otherwise */
rv_blobLoc = 0;
rv_blobSize = nullint;

for(i=0; i<rv_numRets; ++i) {
clipString(retstring[i]);
switch(rv_type[i]) {
case 'D':
yearfirst = false;
if(retstring[i][4] == '-') yearfirst = true;
rv_data[i].l = stringDate(retstring[i],yearfirst);
break;

case 'I':
/* thanks to stringTime(), this works for either hh:mm or hh:mm:ss */
if(retstring[i][0] == 0) rv_data[i].l = nullint;
else {
/* convert space to 0 */
if(retstring[i][1] == ' ') retstring[i][1] = '0';
/* skip the leading space that is produced when Informix converts interval to string */
rv_data[i].l = stringTime(retstring[i]+1);
}
break;

case 'C':
rv_data[i].l = retstring[i][0];
break;

case 'M':
case 'F':
/* null floats look different from null dates and ints. */
if(rv_data[i].l == 0xffffffff) {
rv_data[i].f = nullfloat;
if(rv_type[i] == 'M') rv_data[i].l = nullint;
break;
}
/* represent monitary amounts as an integer number of pennies. */
if(rv_type[i] == 'M')
rv_data[i].l = rv_data[i].f * 100.0 + 0.5;
break;

case 'S':
/* map the empty string into the null string */
l = strlen(retstring[i]);
if(!l) rv_data[i].ptr = 0;
if(l > STRINGLEN) errorPrint("2fetched string is too long, limit %d chars", STRINGLEN);
break;

case 'B':
case 'T':
if(blobstruct.loc_indicator >= 0) { /* not null blob */
rv_blobSize = blobstruct.loc_size;
if(!rv_blobFile) rv_blobLoc = blobstruct.loc_buffer;
if(rv_blobSize == 0) { /* turn empty blob into null blob */
nzFree(rv_blobLoc);
rv_blobLoc = 0;
rv_blobSize = nullint;
}
}
rv_data[i].l = rv_blobSize;
break;

case 'N':
/* Convert from Informix null to our nullint */
if(rv_data[i].l == 0x80000000) rv_data[i].l = nullint;
break;

default:
errorPrint("@bad character %c in retsCleanup", rv_type[i]);
} /* switch on datatype */
} /* loop over columsn fetched */
} /* retsCleanup */

void retsCopy(bool allstrings, void *first, ...)
{
void *q;
int i;

	if(!rv_numRets)
		errorPrint("@calling retsCopy() with no returns pending");

	for(i=0; i<rv_numRets; ++i) {
		if(first) {
			q = first;
			va_start(sqlargs, first);
			first = 0;
		} else {
			q = va_arg(sqlargs, void*);
		}
		if(!q) break;
		if((int)q < 1000 && (int)q > -1000)
			errorPrint("2retsCopy, pointer too close to 0");

if(allstrings) *(char*)q = 0;

if(rv_type[i] == 'S') {
*(char*)q = 0;
if(rv_data[i].ptr)
strcpy(q,  rv_data[i].ptr);
} else if(rv_type[i] == 'C') {
*(char *)q = rv_data[i].l;
if(allstrings) ((char*)q)[1] = 0;
} else if(rv_type[i] == 'F') {
if(allstrings) {
if(isnotnullfloat(rv_data[i].f)) sprintf(q, "%lf", rv_data[i].f);
} else {
*(double *)q = rv_data[i].f;
}
} else if(allstrings) {
char type = rv_type[i];
long l = rv_data[i].l;
if(isnotnull(l)) {
if(type == 'D') {
strcpy(q, dateString(l, DTDELIMIT));
} else if(type == 'I') {
strcpy(q, timeString(l, DTDELIMIT));
} else if(type == 'M') {
sprintf(q, "%ld.%02d", l/100, l%100);
} else sprintf(q, "%ld", l);
}
} else {
*(long *)q = rv_data[i].l;
}
} /* loop over result parameters */

if(!first) va_end(sqlargs);
} /* retsCopy */

/* convert column name into column index */
int findcol_byname(const char *name)
{
	int i;
	for(i=0; rv_name[i][0]; ++i)
		if(stringEqual(name, rv_name[i])) break;
	if(!rv_name[i][0])
		errorPrint("2Column %s not found in the columns or aliases of your select statement", name);
	return i;
} /* findcol_byname */

/* make sure we got one return value, and it is integer compatible */
static long oneRetValue(void)
{
char coltype = rv_type[0];
long n = rv_data[0].l;
if(rv_numRets != 1)
errorPrint("2SQL statement has %d return values, 1 value expected", rv_numRets);
if(!strchr("MNFDIC", coltype))
errorPrint("2SQL statement returns a value whose type is not compatible with a 4-byte integer");
if(coltype == 'F') n = rv_data[0].f;
return n;
} /* oneRetValue */


/*********************************************************************
Prepare a formatted SQL statement.
Gather the types and names of the fetched columns and make this information
available to the rest of the C routines in this file, and to the application.
Returns the populated sqlda structure for the statement.
Returns null if the prepare failed.
*********************************************************************/

static struct sqlda *prepare(const char *stmt_parm, const char *sname_parm)
{
$char*stmt = (char*)stmt_parm;
$char*sname = (char*)sname_parm;
struct sqlda *desc;
struct sqlvar_struct   *v;
short i, coltype;

checkConnect();
if(isnullstring(stmt)) errorPrint("2null SQL statement");
stmt_text = stmt;
debugStatement();

/* look for delete with no where clause */
while(*stmt == ' ') ++stmt;
if(!strncmp(stmt, "delete", 6) || !strncmp(stmt, "update", 6))
/* delete or update */
if(!strstr(stmt, "where") && !strstr(stmt, "WHERE")) {
showStatement();
errorPrint("2Old Mcdonald bug");
}

/* set things up to nulls, in case the prepare fails */
retsSetup(0);
rv_numRets = 0;
memset(rv_type, 0, NUMRETS);
rv_lastNrows = rv_lastRowid = rv_lastSerial = 0;

$prepare :sname from :stmt;
if(errorTrap()) return 0;

/* gather types and column headings */
$describe: sname into desc;
if(!desc) errorPrint("2$describe couldn't allocate descriptor");
rv_numRets = desc->sqld;
if(rv_numRets > NUMRETS) {
showStatement();
errorPrint("2cannot select more than %d values", NUMRETS);
}

  for(i=0,v=desc->sqlvar; i<rv_numRets; ++i,++v ) {
coltype = v->sqltype & SQLTYPE;
/* kludge, count(*) should be int, not float, in my humble opinion */
if(stringEqual(v->sqlname, "(count(*))"))
coltype = SQLINT;

switch(coltype) {
case SQLCHAR:
case SQLVCHAR:
rv_type[i] = 'S';
if(v->sqllen == 1)
rv_type[i] = 'C';
break;

case SQLDTIME:
/* We only process datetime year to minute, for databases
 * other than Informix,  which don't have a date type. */
if(v->sqllen != 5) errorPrint("2datetime field must be year to minute");
case SQLDATE:
rv_type[i] = 'D';
break;

case SQLINTERVAL:
rv_type[i] = 'I';
break;

case SQLSMINT:
case SQLINT:
case SQLSERIAL:
case SQLNULL:
rv_type[i] = 'N';
break;

case SQLFLOAT:
case SQLSMFLOAT:
case SQLDECIMAL:
rv_type[i] = 'F';
break;

case SQLMONEY:
rv_type[i] = 'M';
break;

case SQLBYTES:
rv_type[i] = 'B';
break;

case SQLTEXT:
rv_type[i] = 'T';
break;

default:
errorPrint ("@Unknown informix sql datatype %d", coltype);
} /* switch on type */
} /* loop over returns */

retsSetup(desc);
return desc;
} /* prepare */


/*********************************************************************
Run an SQL statement internally, and gather any fetched values.
This statement stands alone; it fetches at most one row.
You might simply know this, perhaps because of a unique key,
or you might be running a stored procedure.
For efficiency we do not look for a second row, so this is really
like the "select first" construct that some databases support.
A mode variable says whether execution or selection or both are allowed.
Return true if data was successfully fetched.
*********************************************************************/

static bool execInternal(const char *stmt, int mode)
{
struct sqlda *desc;
$static char singlestatement[] = "single_use_stmt";
$static char singlecursor[] = "single_use_cursor";
int i;
bool notfound = false;
short errorcode = 0;

desc = prepare(stmt, singlestatement);
if(!desc) return false; /* error */

if(!rv_numRets) {
if(!(mode&1)) {
showStatement();
errorPrint("2SQL select statement returns no values");
}
$execute :singlestatement;
notfound = true;
} else { /* end no return values */

if(!(mode&2)) {
showStatement();
errorPrint("2SQL statement returns %d values", rv_numRets);
}
$execute: singlestatement into descriptor desc;
}

if(errorTrap()) {
errorcode = rv_vendorStatus;
} else {
/* select or execute ran properly */
/* error 100 means not found in Informix */
if(ENGINE_ERRCODE == 100) notfound = true;
/* set "last" parameters, in case the application is interested */
rv_lastNrows = sqlca.sqlerrd[2];
rv_lastRowid = sqlca.sqlerrd[5];
rv_lastSerial = sqlca.sqlerrd[1];
} /* successful run */

$free :singlestatement;
errorTrap();
nzFree(desc);

retsCleanup();

if(errorcode) {
rv_vendorStatus = errorcode;
rv_lastStatus = errTranslate(rv_vendorStatus);
return false;
}

exclist = 0;
return !notfound;
} /* execInternal */


/*********************************************************************
Run individual select or execute statements, using the above internal routine.
*********************************************************************/

/* pointer to vararg list; most of these are vararg functions */
/* execute a stand-alone statement with no % formatting of the string */
void sql_execNF(const char *stmt)
{
	execInternal(stmt, 1);
} /* sql_execNF */

/* execute a stand-alone statement with % formatting */
void sql_exec(const char *stmt, ...)
{
	va_start(sqlargs, stmt);
	stmt = lineFormatStack(stmt, 0, &sqlargs);
	execInternal(stmt, 1);
	va_end(sqlargs);
} /* sql_exec */

/* run a select statement with no % formatting of the string */
/* return true if the row was found */
bool sql_selectNF(const char *stmt, ...)
{
	bool rc;
	va_start(sqlargs, stmt);
	rc = execInternal(stmt, 2);
	retsCopy(false, 0);
	return rc;
} /* sql_selectNF */

/* run a select statement with % formatting */
bool sql_select(const char *stmt, ...)
{
	bool rc;
	va_start(sqlargs, stmt);
	stmt = lineFormatStack(stmt, 0, &sqlargs);
	rc = execInternal(stmt, 2);
	retsCopy(false, 0);
	return rc;
} /* sql_select */

/* run a select statement with one return value */
int sql_selectOne(const char *stmt, ...)
{
	bool rc;
	va_start(sqlargs, stmt);
	stmt = lineFormatStack(stmt, 0, &sqlargs);
	rc = execInternal(stmt, 2);
		if(!rc) { va_end(sqlargs); return nullint; }
	return oneRetValue();
} /* sql_selectOne */

/* run a stored procedure with no % formatting */
static bool sql_procNF(const char *stmt)
{
	bool rc;
	char *s = allocMem(20+strlen(stmt));
	strcpy(s, "execute procedure ");
	strcat(s, stmt);
	rc = execInternal(s, 3);
	/* if execInternal doesn't return, we have a memory leak */
	nzFree(s);
	return rc;
} /* sql_procNF */

/* run a stored procedure */
bool sql_proc(const char *stmt, ...)
{
	bool rc;
	va_start(sqlargs, stmt);
	stmt = lineFormatStack(stmt, 0, &sqlargs);
	rc = sql_procNF(stmt);
	if(rv_numRets) retsCopy(false, 0);
	return rc;
} /* sql_proc */

/* run a stored procedure with one return */
int sql_procOne(const char *stmt, ...)
{
	bool rc;
	va_start(sqlargs, stmt);
	stmt = lineFormatStack(stmt, 0, &sqlargs);
	rc = sql_procNF(stmt);
		if(!rc) { va_end(sqlargs); return 0; }
	return oneRetValue();
} /* sql_procOne */


/*********************************************************************
Prepare, open, close, and free SQL cursors.
*********************************************************************/

/* prepare a cursor; return the ID number of that cursor */
static int prepareCursor(const char *stmt, bool scrollflag)
{
$char *internal_sname, *internal_cname;
struct OCURS *o = findNewCursor();

stmt = lineFormatStack(stmt, 0, &sqlargs);
va_end(sqlargs);
internal_sname = o->sname;
internal_cname = o->cname;
o->desc = prepare(stmt, internal_sname);
if(!o->desc) return -1;
if(o->desc->sqld == 0) {
showStatement();
errorPrint("2statement passed to sql_prepare has no returns");
}

/* declare with hold;
 * you might run transactions within this cursor. */
if(scrollflag)
$declare :internal_cname scroll cursor with hold for :internal_sname;
else
$declare :internal_cname cursor with hold for :internal_sname;
if(errorTrap()) {
nzFree(o->desc);
return -1;
}

o->numRets = rv_numRets;
memcpy(o->rv_type, rv_type, NUMRETS);
o->flag = CURSOR_PREPARED;
o->fl = 0; /* just to make sure */
return o->cid;
} /* prepareCursor */

int sql_prepare(const char *stmt, ...)
{
	int n;
	va_start(sqlargs, stmt);
	n = prepareCursor(stmt, false);
	exclist = 0;
	return n;
} /* sql_prepare */

int sql_prepareScrolling(const char *stmt, ...)
{
	int n;
	va_start(sqlargs, stmt);
	n = prepareCursor(stmt, true);
	exclist = 0;
	return n;
} /* sql_prepareScrolling */

void sql_open(int cid)
{
short i;
$char *internal_sname, *internal_cname;
struct OCURS *o = findCursor(cid);
if(o->flag == CURSOR_OPENED)
errorPrint("2cannot open cursor %d, already opened", cid);
internal_sname = o->sname;
internal_cname = o->cname;
debugExtra("open");
$open :internal_cname;
if(!errorTrap()) o->flag = CURSOR_OPENED;
o->rownum = 0;
if(o->fl)
for(i=0; i<o->alloc; ++i) {
nzFree(o->fl[i]);
o->fl[i] = 0;
}
exclist = 0;
} /* sql_open */

int sql_prepOpen(const char *stmt, ...)
{
int n;
va_start(sqlargs, stmt);
n = prepareCursor(stmt, false);
if(n < 0) return n;
sql_open(n);
if(rv_lastStatus) {
short ev = rv_vendorStatus;
short el = rv_lastStatus;
sql_free(n);
rv_vendorStatus = ev;
rv_lastStatus = el;
n = -1;
}
return n;
} /* sql_prepOpen */

void sql_close(int cid)
{
$char *internal_sname, *internal_cname;
struct OCURS *o = findCursor(cid);
if(o->flag < CURSOR_OPENED)
errorPrint("2cannot close cursor %d, not yet opened", cid);
internal_cname = o->cname;
debugExtra("close");
$close :internal_cname;
if(errorTrap()) return;
o->flag = CURSOR_PREPARED;
exclist = 0;
} /* sql_close */

void sql_free( int cid)
{
$char *internal_sname, *internal_cname;
struct OCURS *o = findCursor(cid);
if(o->flag == CURSOR_OPENED)
errorPrint("2cannot free cursor %d, not yet closed", cid);
internal_sname = o->sname;
debugExtra("free");
$free :internal_sname;
if(errorTrap()) return;
o->flag = CURSOR_NONE;
nzFree(o->desc);
rv_numRets = 0;
memset(rv_name, 0, sizeof(rv_name));
memset(rv_type, 0, sizeof(rv_type));
if(o->fl) { /* free any cached lines */
short i;
for(i=0; i<o->alloc; ++i)
nzFree(o->fl[i]);
nzFree(o->fl);
o->fl = 0;
o->alloc = 0;
}
exclist = 0;
} /* sql_free */

void sql_closeFree(int cid)
{
const short *exc = exclist;
sql_close(cid);
if(!rv_lastStatus) {
exclist = exc;
sql_free(cid);
}
} /* sql_closeFree */

/* fetch row n from the open cursor.
 * Flag can be used to fetch first, last, next, or previous. */
bool fetchInternal(int cid, long n, int flag, bool remember)
{
$char *internal_sname, *internal_cname;
$long nextrow, lastrow;
struct sqlda *internal_desc;
struct OCURS *o = findCursor(cid);

internal_cname = o->cname;
internal_desc = o->desc;
retsSetup(internal_desc);

/* don't do the fetch if we're looking for row 0 absolute,
 * that just nulls out the return values */
if(flag == 6 && !n) {
o->rownum = 0;
fetchZero:
retsCleanup();
exclist = 0;
return false;
}

lastrow = nextrow = o->rownum;
if(flag == 6) nextrow = n;
if(flag == 3) nextrow = 1;
if(isnotnull(lastrow)) { /* we haven't lost track yet */
if(flag == 1) ++nextrow;
if(flag == 2 && nextrow) --nextrow;
}
if(flag == 4) { /* fetch the last row */
nextrow = nullint; /* we just lost track */
if(o->fl && o->flag == CURSOR_PREPARED) {
/* I'll assume you've read in all the rows, cursor is closed */
for(nextrow=o->alloc-1; nextrow>=0; --nextrow)
if(o->fl[nextrow]) break;
++nextrow;
}
}

if(!nextrow) goto fetchZero;

/* see if we have cached this row */
if(isnotnull(nextrow) && o->fl &&
nextrow <= o->alloc && o->fl[nextrow-1]) {
sql_mkload(o->fl[nextrow-1], '\177');
/* don't run retsCleanup() here */
rv_blobLoc = 0;
rv_blobSize = nullint;
o->rownum = nextrow;
exclist = 0;
return true;
} /* bringing row out of cache */

if(o->flag != CURSOR_OPENED)
errorPrint("2cannot fetch from cursor %d, not yet opened", cid);

/* The next line of code is very subtle.
I use to declare all cursors as scroll cursors.
It's a little inefficient, but who cares.
Then I discovered you can't fetch blobs from scroll cursors.
You can however fetch them from regular cursors,
even with an order by clause.
So cursors became non-scrolling by default.
If the programmer chooses to fetch by absolute number,
but he is really going in sequence, I turn them into
fetch-next statements, so that the cursor need not be a scroll cursor. */
if(flag == 6 &&
isnotnull(lastrow) && isnotnull(nextrow) &&
nextrow == lastrow+1)
flag=1;

debugExtra("fetch");

switch(flag) {
case 1:
$fetch :internal_cname using descriptor internal_desc;
break;
case 2:
$fetch previous :internal_cname using descriptor internal_desc;
break;
case 3:
$fetch first :internal_cname using descriptor internal_desc;
break;
case 4:
$fetch last :internal_cname using descriptor internal_desc;
break;
case 6:
if(isnull(nextrow))
errorPrint("2sql fetches absolute row using null index");
$fetch absolute :nextrow :internal_cname using descriptor internal_desc;
break;
default:
errorPrint("@fetchInternal() receives bad flag %d", flag);
} /* switch */
retsCleanup();

if(errorTrap()) return false;
exclist = 0;
if(ENGINE_ERRCODE == 100) return false; /* not found */
o->rownum = nextrow;

/* remember the unload image of this line */
if(remember)
sql_cursorUpdLine(cid, cloneString(sql_mkunld('\177')));
return true;
} /* fetchInternal */

bool sql_fetchFirst(int cid, ...)
{
	bool rc;
	va_start(sqlargs, cid);
	rc = fetchInternal(cid, 0L, 3, false);
	retsCopy(false, 0);
	return rc;
} /* sql_fetchFirst */

bool sql_fetchLast(int cid, ...)
{
	bool rc;
	va_start(sqlargs, cid);
	rc = fetchInternal(cid, 0L, 4, false);
	retsCopy(false, 0);
	return rc;
} /* sql_fetchLast */

bool sql_fetchNext(int cid, ...)
{
	bool rc;
	va_start(sqlargs, cid);
	rc = fetchInternal(cid, 0L, 1, false);
	retsCopy(false, 0);
	return rc;
} /* sql_fetchNext */

bool sql_fetchPrev(int cid, ...)
{
	bool rc;
	va_start(sqlargs, cid);
	rc = fetchInternal(cid, 0L, 2, false);
	retsCopy(false, 0);
	return rc;
} /* sql_fetchPrev */

bool sql_fetchAbs(int cid, long rownum, ...)
{
	bool rc;
	va_start(sqlargs, rownum);
	rc = fetchInternal(cid, rownum, 6, false);
	retsCopy(false, 0);
	return rc;
} /* sql_fetchAbs */


/* the inverse of sql_mkunld() */
void sql_mkload(const char *line, char delim)
{
char *s, *t;
int data;
short i;

for(i = 0, s = (char*)line; *s; ++i, *t=delim, s = t+1) {
t = strchr(s, delim);
if(!t) errorPrint("2sql load line does not end in a delimiter");
*t = 0;
if(i >= rv_numRets)
errorPrint("2sql load line contains more than %d fields", rv_numRets);

switch(rv_type[i]) {
case 'N':
if(!*s) { data = nullint; break; }
data = strtol(s, &s, 10);
if(*s) errorPrint("2sql load, cannot convert string to integer");
break;

case 'S':
if((unsigned)strlen(s) > STRINGLEN)
errorPrint("2sql load line has a string that is too long");
strcpy(retstring[i], s);
data = (int) retstring[i];
if(!*s) data = 0;
break;

case 'F':
rv_data[i].f = *s ? atof(s) : nullfloat;
continue;

case 'D':
data = stringDate(s,0);
if(data == -1)
errorPrint("2sql load, cannot convert string to date");
break;

case 'C':
data = *s;
if(data && s[1])
errorPrint("2sql load, character field contains more than one character");
break;

case 'I':
data = stringTime(s);
if(data == -1)
errorPrint("2sql load, cannot convert string to time interval");
break;

default:
errorPrint("2sql load cannot convert into type %c", rv_type[i]);
} /* switch on type */

rv_data[i].l = data;
} /* loop over fields in line */

if(i != rv_numRets)
errorPrint("2sql load line contains %d fields, %d expected", i, rv_numRets);
} /* sql_mkload */


/*********************************************************************
We maintain our own cache of fetched lines.
Why?  You might ask.
After all, Informix already maintains a cache of fetched lines.
That's what the open cursor is for.
Looks like serious wheel reinvention to me.
Perhaps, but you can't change the data in the cache that Informix maintains.
This is something Powerbuild et al discovered over a decade ago.
Consider a simple spreadsheet application.
You update the value in one of the cells, thereby updating the row
in the database.  Now scroll down to the next page, and then back again.
If you fetch from the open cursor you will get the old data, before the
change was made, even though the new data is safely ensconsed in the database.
Granted one could reopen the cursor and fetch the new data,
but this can be slow for certain queries (sometimes a couple minutes).
In other words, rebuilding the cursor is not really an option.
So we are forced to retain a copy of the data in our program and change it
whenever we update the database.
Unfortunately the following 3 routines were developed separately,
and they are wildly inconsistent.  Some take a row number while
others assume you are modifying the current row as stored in o->rownum.
Some accept a line of tex, the unload image of the fetch data, while
others build the line of text from the fetched data in rv_data[].
I apologize for this confusion; clearly a redesign is called for.
*********************************************************************/

/* update the text of a fetched line,
 * so we get this same text again when we refetch the line later.
 * These text changes corespond to the database changes that form an update.
 * We assume the line has been allocated using malloc(). */
void sql_cursorUpdLine(int cid, const char *line)
{
struct OCURS *o = findCursor(cid);
int n = o->rownum-1;

if(n >= CACHELIMIT)
errorPrint("2SQL cursor caches too many lines, limit %d", CACHELIMIT);

if(n >= o->alloc) {
/* running off the end, allocate 128 at a time */
short oldalloc = o->alloc;
o->alloc = n + 128;
if(!oldalloc)
o->fl = (char **) allocMem(o->alloc*sizeof(char*));
else
o->fl = (char**) reallocMem((void*)o->fl, o->alloc*sizeof(char*));
memset(o->fl+oldalloc, 0, (o->alloc-oldalloc)*sizeof(char*));
} /* allocating more space */

nzFree(o->fl[n]);
o->fl[n] = (char*)line;
} /* sql_cursorUpdLine */

void sql_cursorDelLine(int cid, int rownum)
{
struct OCURS *o = findCursor(cid);
o->rownum = rownum;
--rownum;
if(rownum >= o->alloc || !o->fl[rownum])
errorPrint("2cursorDelLine(%d)", rownum);
nzFree(o->fl[rownum]);
if(rownum < o->alloc-1)
memcpy(o->fl+rownum, o->fl+rownum+1, (o->alloc-rownum-1)*sizeof(char *));
o->fl[o->alloc-1] = 0;
/* back up the row number if we deleted the last row */
if(!o->fl[rownum]) --o->rownum;
} /* sql_cursorDelLine */

void sql_cursorInsLine(int cid, int rownum)
{
struct OCURS *o = findCursor(cid);
short i;

/* must insert a row within or immediately following the current data */
if(rownum > o->alloc)
errorPrint("2cursorInsLine(%d)", rownum);
/* newly inserted row becomes the current row */
o->rownum = rownum+1;

if(!o->alloc || o->fl[o->alloc-1]) { /* need to make room */
o->alloc += 128;
if(!o->fl)
o->fl = (char **) allocMem(o->alloc*sizeof(char*));
else
o->fl = (char**) reallocMem((void*)o->fl, o->alloc*sizeof(char*));
memset(o->fl+o->alloc-128, 0, 128*sizeof(char*));
} /* allocating more space */

/* move the rest of the lines down */
for(i=o->alloc-1; i>rownum; --i)
o->fl[i] = o->fl[i-1];
o->fl[i] = cloneString(sql_mkunld('\177'));
} /* sql_cursorInsLine */


/*********************************************************************
run the analog of /bin/comm on two open cursors,
rather than two Unix files.
This assumes a common unique key that we use to sync up the rows.
The cursors should be sorted by this key.
*********************************************************************/

void cursor_comm(
const char *stmt1, const char *stmt2, /* the two select statements */
const char *orderby, /* which fetched column is the unique key */
fnptr f, /* call this function for differences */
char delim) /* sql_mkunld() delimiter, or call mkinsupd if delim = 0 */
{
short cid1, cid2; /* the cursor ID numbers */
char *line1, *line2, *s; /* the two fetched rows */
void *blob1, *blob2; /* one blob per table */
int blob1size, blob2size;
bool eof1, eof2, get1, get2;
int sortval1, sortval2;
char sortstring1[80], sortstring2[80];
int sortcol;
char sorttype;
int passkey1, passkey2;
static const char sortnull[] = "cursor_comm, sortval%d is null";
static const char sortlong[] = "cursor_comm cannot key on strings longer than %d";
static const char noblob[] = "sorry, cursor_comm cannot handle blobs yet";

cid1 = sql_prepOpen(stmt1);
cid2 = sql_prepOpen(stmt2);

sortcol = findcol_byname(orderby);
sorttype = rv_type[sortcol];
if(charInList("NDIS", sorttype) < 0)
errorPrint("2cursor_com(), column %s has bad type %c", orderby, sorttype);
if(sorttype == 'S')
passkey1 = (int)sortstring1, passkey2 = (int)sortstring2;

eof1 = eof2 = false;
get1 = get2 = true;
rv_blobFile = 0; /* in case the cursor has a blob */
line1 = line2 = 0;
blob1 = blob2 = 0;

while(true) {
if(get1) { /* fetch first row */
eof1 = !sql_fetchNext(cid1, 0);
nzFree(line1);
line1 = 0;
nzFree(blob1);
blob1 = 0;
if(!eof1) {
if(sorttype == 'S') {
s = rv_data[sortcol].ptr;
if(isnullstring(s)) errorPrint(sortnull, 1);
if(strlen(s) >= sizeof(sortstring1))
errorPrint(sortlong, sizeof(sortstring1));
strcpy(sortstring1, s);
} else {
passkey1 = sortval1 = rv_data[sortcol].l;
if(isnull(sortval1))
errorPrint(sortnull, 1);
}
line1 = cloneString(delim ? sql_mkunld(delim) : sql_mkinsupd());
if(rv_blobLoc) {
blob1 = rv_blobLoc;
blob1size = rv_blobSize;
errorPrint(noblob);
}
} /* not eof */
} /* looking for first line */

if(get2) { /* fetch second row */
eof2 = !sql_fetchNext(cid2, 0);
nzFree(line2);
line2 = 0;
nzFree(blob2);
blob2 = 0;
if(!eof2) {
if(sorttype == 'S') {
s = rv_data[sortcol].ptr;
if(isnullstring(s)) errorPrint(sortnull, 2);
if(strlen(s) >= sizeof(sortstring2))
errorPrint(sortlong, sizeof(sortstring2));
strcpy(sortstring2, rv_data[sortcol].ptr);
} else {
passkey2 = sortval2 = rv_data[sortcol].l;
if(isnull(sortval2))
errorPrint(sortnull, 2);
}
line2 = cloneString(delim ? sql_mkunld(delim) : sql_mkinsupd());
if(rv_blobLoc) {
blob2 = rv_blobLoc;
blob2size = rv_blobSize;
errorPrint(noblob);
}
} /* not eof */
} /* looking for second line */

if(eof1 & eof2) break; /* done */
get1 = get2 = false;

/* in cid2, but not in cid1 */
if(eof1 || !eof2 &&
(sorttype == 'S' && strcmp(sortstring1, sortstring2) > 0 ||
sorttype != 'S' && sortval1 > sortval2)) {
(*f)('>', line1, line2, passkey2);
get2 = true;
continue;
}

/* in cid1, but not in cid2 */
if(eof2 || !eof1 &&
(sorttype == 'S' && strcmp(sortstring1, sortstring2) < 0 ||
sorttype != 'S' && sortval1 < sortval2)) {
(*f)('<', line1, line2, passkey1);
get1 = true;
continue;
} /* insert case */

get1 = get2 = true;
/* perhaps the lines are equal */
if(stringEqual(line1, line2)) continue;

/* lines are different between the two cursors */
(*f)('*', line1, line2, passkey2);
} /* loop over parallel cursors */

nzFree(line1);
nzFree(line2);
nzFree(blob1);
nzFree(blob2);
sql_closeFree(cid1);
sql_closeFree(cid2);
} /* cursor_comm */

/*********************************************************************
Get the primary key for a table.
In informix, you can use system tables to get this information.
There's a way to do it in odbc, but I don't remember.
*********************************************************************/

void
getPrimaryKey(char *tname, int *part1, int *part2)
{
int p1, p2, rc;
char *s = strchr(tname, ':');
*part1 = *part2 = 0;
if(!s) {
rc = sql_select("select part1, part2 \
from sysconstraints c, systables t, sysindexes i \
where tabname = %S and t.tabid = c.tabid \
and constrtype = 'P' and c.idxname = i.idxname",
tname, &p1, &p2);
} else {
*s = 0;
rc = sql_select("select part1, part2 \
from %s:sysconstraints c, %s:systables t, %s:sysindexes i \
where tabname = %S and t.tabid = c.tabid \
and constrtype = 'P' and c.idxname = i.idxname",
tname, tname, tname, s+1, &p1, &p2);
*s = ':';
}
if(rc) *part1 = p1, *part2 = p2;
} /* getPrimaryKey */
