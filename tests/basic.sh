#!/bin/sh
set -e

zig build
zig build run &
SERVER_PROCESS_PID=$!

cleanup() {
    kill $SERVER_PROCESS_PID
    wait $SERVER_PROCESS_PID
}

trap cleanup EXIT

http POST 127.0.0.1:35866/transactions payer=DANNON points:=1000 timestamp="2020-11-02T14:00:00Z"
http POST 127.0.0.1:35866/transactions payer=UNILEVER points:=200 timestamp="2020-10-31T11:00:00Z"
http POST 127.0.0.1:35866/transactions payer="MILLER COORS" points:=10000 timestamp="2020-11-01T14:00:00Z"
http POST 127.0.0.1:35866/transactions payer=DANNON points:=300 timestamp="2020-10-31T10:00:00Z"
http POST 127.0.0.1:35866/transactions payer=DANNON points:=-200 timestamp="2020-10-31T15:00:00Z"

http POST 127.0.0.1:35866/spend points:=5000

http 127.0.0.1:35866/balance
