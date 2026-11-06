#!/usr/bin/env bash

curl -s http://hal:8002/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
       "model": "knowline-4b",
       "prompt": "<|im_start|>user\nContext: I was charged twice for my subscription this month. Please refund the extra charge.\n\nQuestion: Which option best describes the tone of the context?\nA) Angry\nB) Calm\nC) Excited\n\nAnswer:<|im_end|>\n<|im_start|>assistant\n",
       "temperature": 0.0,
       "max_tokens": 1,
       "logprobs": 5
     }' | jq .

