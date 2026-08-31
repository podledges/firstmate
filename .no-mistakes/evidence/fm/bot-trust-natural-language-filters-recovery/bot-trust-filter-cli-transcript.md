# Bot Trust natural-language filter CLI transcript

$ FM_BOT_TRUST_RANDOM_HEX=00 bin/fm-bot-trust-filter.sh "flip a coin with a 70% chance"
1

$ FM_BOT_TRUST_RANDOM_HEX=270f bin/fm-bot-trust-filter.sh "choose randomly with a 70 percent probability"
0

$ FM_BOT_TRUST_RANDOM_HEX=00 bin/fm-bot-trust-filter.sh "70 percent"
1

$ FM_BOT_TRUST_RANDOM_HEX=not-hex bin/fm-bot-trust-filter.sh "the chance of rain is 70%"; echo "exit=$?"
exit=1

$ FM_BOT_TRUST_RANDOM_HEX=not-hex bin/fm-bot-trust-filter.sh "choose with a 30% or 70% chance"; echo "exit=$?"
exit=1
