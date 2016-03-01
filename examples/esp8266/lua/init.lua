function startup()
    print('Starting...')
    dofile('script1.lua')
    end

-- wait 5 sec before continuing
-- so one could abort the (next) start
-- by removing init.lua
-- in the mean time
print('Will start in 5 seconds')
tmr.alarm(0,5000,0,startup)