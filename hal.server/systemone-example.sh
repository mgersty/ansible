#!/usr/bin/env bash
# Typed decision questions via llama-cpp.service's native /v1/systemone
# endpoint (TypeSafe System 1 format, llama.cpp build b11361+,
# ggml-org/llama.cpp#29818).
#
# llama-cpp.service runs the llama.cpp model router, so the "model" field
# (same level as "state") picks the decision model -- kev-4b by default.
# Question types:
#   choice  options (+ optional descriptions) -> top option + probability each
#   score   2-10 levels, lowest first          -> expected level (can be fractional)
#   noul    yes/no question                    -> probability of yes
set -euo pipefail

curl -s http://hal:8000/v1/systemone \
  -H "Content-Type: application/json" \
  -d '{
    "model": "kev-4b",
    "state": "Customer message: I was charged twice for my order last week and nobody has replied.",
    "questions": {
      "route": {
        "type": "choice",
        "instructions": "Which team should handle this?",
        "criteria": {
          "billing": "payments, charges, refunds, invoices",
          "shipping": "delivery, tracking, lost or late parcels",
          "technical": "bugs, errors, login problems"
        }
      },
      "angry": {
        "type": "noul",
        "instructions": "Is the customer angry?"
      },
      "urgency": {
        "type": "score",
        "instructions": "How urgent is this?",
        "criteria": ["can wait", "this week", "today", "right now"]
      }
    }
  }' | jq .
