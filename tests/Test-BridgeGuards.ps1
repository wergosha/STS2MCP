param([string]$SourcePath = (Join-Path $PSScriptRoot '..\McpMod.cs'))

$ErrorActionPreference = 'Stop'

# Compile the production methods with lightweight dependencies, then exercise
# the queue and a real loopback HTTP listener without loading the game.
$sourceText = Get-Content -LiteralPath $SourcePath -Raw
$queueMethod = [regex]::Match($sourceText, '(?s)    private static void ProcessMainThreadQueue\(\).*?(?=    internal static Task<T>)').Value
$requestMethod = [regex]::Match($sourceText, '(?s)    private static void HandleRequest\(HttpListenerContext context\).*?(?=    // Called on HTTP thread)').Value
if (!$queueMethod -or !$requestMethod) { throw 'Could not extract production methods' }

$harness = @"
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
public static class STS2BridgeRegression
{
    private const string Version = "test";
    private static readonly ConcurrentQueue<Action> _mainThreadQueue = new();
    private static int _dispatchCount;
    private static class GD { public static void PrintErr(string value) { throw new Exception(value); } }
$queueMethod
$requestMethod
    private static bool IsMultiplayerRun() => false;
    private static void SendJson(HttpListenerResponse response, object value) => Respond(response, 200, "{}");
    private static void SendError(HttpListenerResponse response, int status, string error) => Respond(response, status, error);
    private static void Respond(HttpListenerResponse response, int status, string body)
    {
        response.StatusCode = status;
        var bytes = Encoding.UTF8.GetBytes(body);
        response.ContentLength64 = bytes.Length;
        response.OutputStream.Write(bytes);
        response.Close();
    }
    private static void HandleGetState(HttpListenerRequest request, HttpListenerResponse response) => SendJson(response, new {});
    private static void HandlePostAction(HttpListenerRequest request, HttpListenerResponse response)
    {
        _dispatchCount++;
        SendJson(response, new {});
    }
    private static void HandleGetMultiplayerState(HttpListenerRequest request, HttpListenerResponse response) => SendJson(response, new {});
    private static void HandlePostMultiplayerAction(HttpListenerRequest request, HttpListenerResponse response) => HandlePostAction(request, response);
    private static void HandleGetProfiles(HttpListenerResponse response) => SendJson(response, new {});
    private static void HandlePostProfiles(HttpListenerRequest request, HttpListenerResponse response) => HandlePostAction(request, response);
    private static void HandleGetProfile(HttpListenerResponse response) => SendJson(response, new {});
    private static void HandleGetCompendium(HttpListenerResponse response) => SendJson(response, new {});
    private static void HandleGetWiki(HttpListenerRequest request, HttpListenerResponse response) => SendJson(response, new {});
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static string Run()
    {
        _dispatchCount = 0;
        var executed = new List<int>();
        for (int i = 0; i < 11; i++) { int item = i; _mainThreadQueue.Enqueue(() => executed.Add(item)); }
        ProcessMainThreadQueue();
        Check(executed.Count == 10 && _mainThreadQueue.Count == 1, "11th queued request must remain after first frame");
        ProcessMainThreadQueue();
        Check(executed.Count == 11 && executed[10] == 10 && _mainThreadQueue.IsEmpty, "11th queued request must execute next frame");

        var reservation = new TcpListener(IPAddress.Loopback, 0);
        reservation.Start();
        int port = ((IPEndPoint)reservation.LocalEndpoint).Port;
        reservation.Stop();
        using var listener = new HttpListener();
        listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
        listener.Start();
        using var client = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(5) };
        var cases = new[] {
            (method: HttpMethod.Post, origin: "https://example.com", status: 403, dispatches: 0),
            (method: HttpMethod.Post, origin: "null", status: 403, dispatches: 0),
            (method: HttpMethod.Options, origin: "https://example.com", status: 403, dispatches: 0),
            (method: HttpMethod.Post, origin: (string)null, status: 200, dispatches: 1),
            (method: HttpMethod.Get, origin: (string)null, status: 200, dispatches: 1)
        };
        foreach (var item in cases)
        {
            using var request = new HttpRequestMessage(item.method, "http://127.0.0.1:" + port + "/api/v1/singleplayer");
            if (item.origin != null) request.Headers.Add("Origin", item.origin);
            if (item.method == HttpMethod.Post) request.Content = new StringContent("{\"action\":\"end_turn\"}", Encoding.UTF8, "text/plain");
            var contextTask = listener.GetContextAsync();
            var responseTask = client.SendAsync(request);
            HandleRequest(contextTask.GetAwaiter().GetResult());
            using var response = responseTask.GetAwaiter().GetResult();
            Check((int)response.StatusCode == item.status, "Unexpected status for " + item.method + " with Origin " + item.origin);
            Check(_dispatchCount == item.dispatches, "Origin request reached action dispatch");
            Check(!response.Headers.Contains("Access-Control-Allow-Origin"), "Permissive CORS header must be absent");
        }
        return "PASS: queue retains request 11; Origin POST/null/preflight blocked before dispatch; no-Origin POST/GET accepted; CORS absent.";
    }
}
"@

Add-Type -TypeDefinition $harness
[STS2BridgeRegression]::Run()
