module vibe.db.postgresql;

@trusted:

public import dpq2.result;
public import dpq2.connection: ConnectionException, connStringCheck, ConnectionStart;
public import dpq2.query: QueryParams;
public import derelict.pq.pq;
import dpq2: ValueFormat, Dpq2Exception, WaitType;
import vibeConnPool = vibe.core.connectionpool;
import vibe.core.concurrency;
import std.experimental.logger;
import core.time: Duration;
import std.exception: enforce;

PostgresClient connectPostgresDB(string connString, uint connNum)
{
    return new PostgresClient(connString, connNum);
}

class PostgresClient
{
    private alias TConnection = dpq2.Connection;
    private alias VibePool = vibeConnPool.ConnectionPool!Connection;

    private const string connString;
    private const void delegate(TConnection) afterConnect;
    private const void delegate(TConnection) afterReset;
    private VibePool pool;

    this(
        string connString,
        uint connNum,
        void delegate(TConnection) @trusted afterConnect = null,
        void delegate(TConnection) @trusted afterReset = null
    )
    {
        connString.connStringCheck;
        this.connString = connString;
        this.afterConnect = afterConnect;
        this.afterReset = afterReset;

        pool = new VibePool({ return new Connection; }, connNum);
    }

    class Connection : TConnection
    {
        private this()
        {
            super(ConnectionStart(), connString);

            if(afterConnect) afterConnect(this);
        }

        override void resetStart()
        {
            super.resetStart;

            if(afterReset) afterReset(this);
        }
    }

    LockedConnection lockConnection()
    {
        trace("get connection from a pool");

        return new LockedConnection(pool.lockConnection);
    }
}

class LockedConnection
{
    private alias VibeLockedConnection = vibeConnPool.LockedConnection!(PostgresClient.Connection);

    VibeLockedConnection conn;
    alias conn this;

    private this(VibeLockedConnection conn)
    {
        this.conn = conn;
    }

    ~this()
    {
        conn.destroy(); // immediately revert locked connection into a pool
    }

    private void doQuery(void delegate() doesQueryAndCollectsResults)
    {
        // Try to get usable connection and send SQL command
        try
        {
            while(true)
            {
                auto pollRes = conn.poll;

                if(pollRes != PGRES_POLLING_OK)
                {
                    // waiting for socket changes for reading
                    conn.waitEndOf(WaitType.READ); // FIXME: need timeout check
                    continue;
                }

                break;
            }

            trace("doesQuery() call");
            doesQueryAndCollectsResults();
            return;
        }
        catch(ConnectionException e)
        {
            // this block just starts reconnection and immediately loops back
            warning("Connection failed: ", e.msg);

            assert(conn, "conn isn't initialised (conn == null)");

            // try to restore connection because pool isn't do this job by itself
            try
            {
                trace("try to restore not null connection");
                conn.resetStart();
            }
            catch(ConnectionException e)
            {
                warning("Connection restore failed: ", e.msg);
            }

            throw e;
        }
    }

    private immutable(Result) runStatementBlockingManner(void delegate() sendsStatement, Duration timeout)
    {
        trace("runStatementBlockingManner");
        immutable(Result)[] res;

        doQuery(()
            {
                sendsStatement();
                bool timeoutNotOccurred = conn.waitEndOf(WaitType.READ, timeout);

                if(!timeoutNotOccurred) // query timeout occurred
                {
                    trace("Exceeded Posgres query time limit");
                    conn.cancel(); // cancel sql query
                }

                trace("consumeInput()");
                conn.consumeInput();

                while(true)
                {
                    trace("getResult()");
                    auto r = conn.getResult();
                    if(r is null) break;
                    res ~= r;
                }

                enforce(res.length <= 1, "simple query can return only one Result instance");

                if(!timeoutNotOccurred && res.length != 1) // query timeout occured and result isn't received
                    throw new PostgresClientException("Exceeded Posgres query time limit", __FILE__, __LINE__);
            }
        );

        enforce(res.length == 1, "Result isn't received?");

        return res[0];
    }

    immutable(Answer) execStatement(
        string sqlCommand,
        ValueFormat resultFormat = ValueFormat.TEXT,
        Duration timeout = Duration.zero
    )
    {
        QueryParams p;
        p.resultFormat = resultFormat;
        p.sqlCommand = sqlCommand;

        return execStatement(p, timeout);
    }

    immutable(Answer) execStatement(QueryParams params, Duration timeout = Duration.zero)
    {
        auto res = runStatementBlockingManner({ conn.sendQuery(params); }, timeout);

        return res.getAnswer;
    }

    void prepareStatement(
        string statementName,
        string sqlStatement,
        size_t nParams,
        Duration timeout = Duration.zero
    )
    {
        auto r = runStatementBlockingManner(
                {conn.sendPrepare(statementName, sqlStatement, nParams);},
                timeout
            );

        if(r.status != PGRES_COMMAND_OK)
            throw new PostgresClientException(r.resultErrorMessage, __FILE__, __LINE__);
    }

    immutable(Answer) execPreparedStatement(QueryParams params, Duration timeout = Duration.zero)
    {
        auto res = runStatementBlockingManner({ conn.sendQueryPrepared(params); }, timeout);

        return res.getAnswer;
    }
}

class PostgresClientException : Dpq2Exception
{
    this(string msg, string file, size_t line)
    {
        super(msg, file, line);
    }
}

unittest
{
    bool raised = false;

    try
    {
        auto client = connectPostgresDB("wrong connect string", 2);
    }
    catch(ConnectionException e)
        raised = true;

    assert(raised);
}

version(IntegrationTest) void __integration_test(string connString)
{
    auto client = connectPostgresDB(connString, 3);
    auto conn = client.lockConnection();

    {
        auto res1 = conn.execStatement(
            "SELECT 123::integer, 567::integer, 'asd fgh'::text",
            ValueFormat.BINARY,
            dur!"seconds"(5)
        );

        assert(res1.getAnswer[0][1].as!PGinteger == 567);
    }

    {
        conn.prepareStatement("stmnt_name", "SELECT 123::integer", 0, dur!"seconds"(5));

        bool throwFlag = false;

        try
            conn.prepareStatement("wrong_stmnt", "WRONG SQL STATEMENT", 0, dur!"seconds"(5));
        catch(PostgresClientException e)
            throwFlag = true;

        assert(throwFlag);
    }

    {
        QueryParams p;
        p.preparedStatementName = "stmnt_name";

        auto r = conn.execPreparedStatement(p, dur!"seconds"(5));

        assert(r.getAnswer[0][0].as!PGinteger == 123);
    }

    {
        assert(conn.escapeIdentifier("abc") == "\"abc\"");
    }
}
