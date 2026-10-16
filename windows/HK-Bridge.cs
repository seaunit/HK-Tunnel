using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class HKBridge
{
    private static int _listenPort = 1081;
    private static int _socksPort = 1080;
    private static int _ownerPid;
    private static volatile bool _stopping;
    private static TcpListener _listener;

    public static int Main(string[] args)
    {
        try
        {
            ParseArguments(args);
            _listener = new TcpListener(IPAddress.Loopback, _listenPort);
            _listener.Start();

            if (_ownerPid > 0)
            {
                Thread monitor = new Thread(new ThreadStart(MonitorOwner));
                monitor.IsBackground = true;
                monitor.Start();
            }

            Console.WriteLine("READY " + _listenPort.ToString());
            Console.Out.Flush();

            while (!_stopping)
            {
                TcpClient client;
                try
                {
                    client = _listener.AcceptTcpClient();
                }
                catch (SocketException)
                {
                    if (_stopping)
                    {
                        break;
                    }
                    throw;
                }

                client.NoDelay = true;
                // These deadlines only cover the request-header phase. They are
                // cleared again before the connection is relayed, because a
                // relayed connection may legitimately stay quiet for minutes:
                // an API that thinks before its first token, an SSE stream with
                // a long gap, or an HTTPS connection parked in a client's
                // keep-alive pool between requests.
                client.ReceiveTimeout = 30000;
                client.SendTimeout = 30000;
                ThreadPool.QueueUserWorkItem(new WaitCallback(HandleClient), client);
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
        finally
        {
            if (_listener != null)
            {
                try { _listener.Stop(); }
                catch { }
            }
        }
    }

    private static void ParseArguments(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (arg == "--listen" && i + 1 < args.Length)
            {
                _listenPort = Int32.Parse(args[++i]);
            }
            else if (arg == "--socks" && i + 1 < args.Length)
            {
                _socksPort = Int32.Parse(args[++i]);
            }
            else if (arg == "--owner-pid" && i + 1 < args.Length)
            {
                _ownerPid = Int32.Parse(args[++i]);
            }
        }

        if (_listenPort < 1024 || _listenPort > 65535)
        {
            throw new ArgumentException("Invalid listen port.");
        }
        if (_socksPort < 1 || _socksPort > 65535)
        {
            throw new ArgumentException("Invalid SOCKS port.");
        }
    }

    private static void MonitorOwner()
    {
        while (!_stopping)
        {
            Thread.Sleep(1000);
            try
            {
                Process.GetProcessById(_ownerPid);
            }
            catch
            {
                _stopping = true;
                try { _listener.Stop(); }
                catch { }
                return;
            }
        }
    }

    private static void HandleClient(object state)
    {
        TcpClient client = (TcpClient)state;
        NetworkStream clientStream = null;
        TcpClient remote = null;

        try
        {
            clientStream = client.GetStream();

            byte[] headerBytes;
            byte[] extraBytes;
            if (!TryReadRequestHeader(clientStream, out headerBytes, out extraBytes))
            {
                return;
            }

            string headerText = Encoding.ASCII.GetString(headerBytes);
            int firstLineEnd = headerText.IndexOf("\r\n", StringComparison.Ordinal);
            if (firstLineEnd < 0)
            {
                return;
            }

            string requestLine = headerText.Substring(0, firstLineEnd);
            string[] requestParts = requestLine.Split(' ');
            if (requestParts.Length < 3)
            {
                SendError(clientStream, "400 Bad Request");
                return;
            }

            string method = requestParts[0];
            string target = requestParts[1];

            if (method.Equals("CONNECT", StringComparison.OrdinalIgnoreCase))
            {
                string host;
                int port;
                ParseAuthority(target, 443, out host, out port);
                remote = SocksConnect(host, port);
                NetworkStream remoteStream = remote.GetStream();

                byte[] connected = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 200 Connection Established\r\n" +
                    "Proxy-Agent: HK-Tunnel\r\n\r\n");
                clientStream.Write(connected, 0, connected.Length);
                clientStream.Flush();

                if (extraBytes.Length > 0)
                {
                    remoteStream.Write(extraBytes, 0, extraBytes.Length);
                    remoteStream.Flush();
                }

                EnterRelayMode(client, remote);
                Relay(clientStream, remoteStream);
                return;
            }

            Uri uri;
            if (!Uri.TryCreate(target, UriKind.Absolute, out uri) ||
                !uri.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase))
            {
                SendError(clientStream, "400 Bad Request");
                return;
            }

            remote = SocksConnect(uri.Host, uri.Port);
            NetworkStream originStream = remote.GetStream();

            string originTarget = uri.PathAndQuery;
            if (String.IsNullOrEmpty(originTarget))
            {
                originTarget = "/";
            }

            StringBuilder rewritten = new StringBuilder();
            rewritten.Append(method);
            rewritten.Append(' ');
            rewritten.Append(originTarget);
            rewritten.Append(' ');
            rewritten.Append(requestParts[2]);
            rewritten.Append("\r\n");

            bool connectionHeaderAdded = false;
            string remainder = headerText.Substring(firstLineEnd + 2);
            string[] headerLines = remainder.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            for (int i = 0; i < headerLines.Length; i++)
            {
                string line = headerLines[i];
                if (line.Length == 0)
                {
                    continue;
                }

                string lower = line.ToLowerInvariant();
                if (lower.StartsWith("proxy-connection:", StringComparison.Ordinal) ||
                    lower.StartsWith("proxy-authorization:", StringComparison.Ordinal))
                {
                    continue;
                }
                if (lower.StartsWith("connection:", StringComparison.Ordinal))
                {
                    rewritten.Append("Connection: close\r\n");
                    connectionHeaderAdded = true;
                    continue;
                }

                rewritten.Append(line);
                rewritten.Append("\r\n");
            }

            if (!connectionHeaderAdded)
            {
                rewritten.Append("Connection: close\r\n");
            }
            rewritten.Append("\r\n");

            byte[] rewrittenBytes = Encoding.ASCII.GetBytes(rewritten.ToString());
            originStream.Write(rewrittenBytes, 0, rewrittenBytes.Length);
            if (extraBytes.Length > 0)
            {
                originStream.Write(extraBytes, 0, extraBytes.Length);
            }
            originStream.Flush();

            EnterRelayMode(client, remote);
            Relay(clientStream, originStream);
        }
        catch (Exception ex)
        {
            try
            {
                if (clientStream != null)
                {
                    SendError(clientStream, "502 Bad Gateway");
                }
            }
            catch { }

            Console.Error.WriteLine(ex.Message);
        }
        finally
        {
            if (remote != null)
            {
                try { remote.Close(); }
                catch { }
            }
            try { client.Close(); }
            catch { }
        }
    }

    private static bool TryReadRequestHeader(NetworkStream stream, out byte[] header, out byte[] extra)
    {
        header = null;
        extra = null;
        MemoryStream buffer = new MemoryStream();
        byte[] chunk = new byte[4096];
        int scanned = 0;

        while (buffer.Length < 131072)
        {
            int read = stream.Read(chunk, 0, chunk.Length);
            if (read <= 0)
            {
                return false;
            }

            buffer.Write(chunk, 0, read);
            byte[] data = buffer.ToArray();
            int end = FindHeaderEnd(data, Math.Max(0, scanned - 3));
            if (end >= 0)
            {
                int headerLength = end + 4;
                header = new byte[headerLength];
                Array.Copy(data, 0, header, 0, headerLength);

                int extraLength = data.Length - headerLength;
                extra = new byte[extraLength];
                if (extraLength > 0)
                {
                    Array.Copy(data, headerLength, extra, 0, extraLength);
                }
                return true;
            }

            scanned = data.Length;
        }

        throw new InvalidDataException("Request header is too large.");
    }

    private static int FindHeaderEnd(byte[] data, int start)
    {
        for (int i = start; i <= data.Length - 4; i++)
        {
            if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10)
            {
                return i;
            }
        }
        return -1;
    }

    private static void ParseAuthority(string authority, int defaultPort, out string host, out int port)
    {
        host = authority;
        port = defaultPort;

        if (authority.StartsWith("[", StringComparison.Ordinal))
        {
            int close = authority.IndexOf(']');
            if (close < 0)
            {
                throw new InvalidDataException("Invalid IPv6 authority.");
            }

            host = authority.Substring(1, close - 1);
            if (close + 1 < authority.Length && authority[close + 1] == ':')
            {
                port = Int32.Parse(authority.Substring(close + 2));
            }
            return;
        }

        int colon = authority.LastIndexOf(':');
        if (colon > 0 && authority.IndexOf(':') == colon)
        {
            host = authority.Substring(0, colon);
            port = Int32.Parse(authority.Substring(colon + 1));
        }
    }

    private static TcpClient SocksConnect(string host, int port)
    {
        TcpClient client = new TcpClient();
        client.NoDelay = true;
        // Deadlines guard the SOCKS handshake so a wedged tunnel does not pin a
        // worker thread forever. EnterRelayMode clears them once the connection
        // is carrying real traffic.
        client.ReceiveTimeout = 15000;
        client.SendTimeout = 15000;
        client.Connect(IPAddress.Loopback, _socksPort);
        NetworkStream stream = client.GetStream();

        byte[] greeting = new byte[] { 5, 1, 0 };
        stream.Write(greeting, 0, greeting.Length);
        stream.Flush();

        byte[] greetingReply = ReadExact(stream, 2);
        if (greetingReply[0] != 5 || greetingReply[1] != 0)
        {
            throw new IOException("SOCKS5 server rejected the connection.");
        }

        List<byte> request = new List<byte>();
        request.Add(5);
        request.Add(1);
        request.Add(0);

        IPAddress address;
        if (IPAddress.TryParse(host, out address))
        {
            byte[] addressBytes = address.GetAddressBytes();
            request.Add((byte)(addressBytes.Length == 4 ? 1 : 4));
            request.AddRange(addressBytes);
        }
        else
        {
            byte[] hostBytes = Encoding.ASCII.GetBytes(host);
            if (hostBytes.Length > 255)
            {
                throw new InvalidDataException("Host name is too long.");
            }
            request.Add(3);
            request.Add((byte)hostBytes.Length);
            request.AddRange(hostBytes);
        }

        request.Add((byte)(port >> 8));
        request.Add((byte)(port & 255));
        byte[] requestBytes = request.ToArray();
        stream.Write(requestBytes, 0, requestBytes.Length);
        stream.Flush();

        byte[] reply = ReadExact(stream, 4);
        if (reply[0] != 5 || reply[1] != 0 || reply[2] != 0)
        {
            throw new IOException("SOCKS5 connect failed with code " + reply[1].ToString());
        }

        int addressType = reply[3];
        if (addressType == 1)
        {
            ReadExact(stream, 6);
        }
        else if (addressType == 4)
        {
            ReadExact(stream, 18);
        }
        else if (addressType == 3)
        {
            byte[] length = ReadExact(stream, 1);
            ReadExact(stream, length[0] + 2);
        }
        else
        {
            throw new IOException("SOCKS5 server returned an invalid address type.");
        }

        return client;
    }

    private static byte[] ReadExact(NetworkStream stream, int count)
    {
        byte[] data = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int read = stream.Read(data, offset, count - offset);
            if (read <= 0)
            {
                throw new EndOfStreamException();
            }
            offset += read;
        }
        return data;
    }

    // A relayed connection is never given an idle deadline: the two peers decide
    // when the conversation is over, and "quiet" is not the same as "dead". Liveness
    // is left to TCP keep-alive instead, which only gives up when probes go
    // unanswered - so a peer that vanished is still reaped, but a peer that is
    // merely thinking, streaming slowly or holding a pooled HTTPS connection is not.
    private static void EnterRelayMode(TcpClient client, TcpClient remote)
    {
        Relax(client);
        Relax(remote);
    }

    private static void Relax(TcpClient connection)
    {
        try
        {
            connection.ReceiveTimeout = 0;
            connection.SendTimeout = 0;
            connection.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);

            // 30s idle before the first probe, then a probe every 10s.
            byte[] keepAlive = new byte[12];
            BitConverter.GetBytes(30000).CopyTo(keepAlive, 0);
            BitConverter.GetBytes(10000).CopyTo(keepAlive, 4);
            connection.Client.IOControl(IOControlCode.KeepAliveValues, keepAlive, null);
        }
        catch
        {
            // Best effort: a stack that refuses the keep-alive tuning still gets
            // the cleared timeouts above, which is the part that matters.
        }
    }

    private static void Relay(NetworkStream client, NetworkStream remote)
    {
        Thread upload = new Thread(delegate()
        {
            CopyStream(client, remote);
        });
        upload.IsBackground = true;
        upload.Start();

        CopyStream(remote, client);
    }

    private static void CopyStream(Stream source, Stream destination)
    {
        byte[] buffer = new byte[32768];
        try
        {
            while (true)
            {
                int read = source.Read(buffer, 0, buffer.Length);
                if (read <= 0)
                {
                    return;
                }
                destination.Write(buffer, 0, read);
                destination.Flush();
            }
        }
        catch
        {
        }
    }

    private static void SendError(NetworkStream stream, string status)
    {
        string response =
            "HTTP/1.1 " + status + "\r\n" +
            "Content-Length: 0\r\n" +
            "Connection: close\r\n\r\n";
        byte[] data = Encoding.ASCII.GetBytes(response);
        stream.Write(data, 0, data.Length);
        stream.Flush();
    }
}
