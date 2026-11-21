#!/usr/bin/env python3
"""Prints the scipy reference values hard-coded in CardioKit/Tests/SignalProcessingTests/FilterTests.swift.

The Swift Butterworth design is checked against scipy.signal.butter (+ sosfreqz / sosfiltfilt).
Re-run after changing the filter design and compare."""
import numpy as np
from scipy import signal
fs=100.0
cases=[("lp",4,10.0,None),("hp",4,5.0,None),("lp",3,2.0,None),("hp",3,0.5,None),("bp",2,5.0,30.0),("bp",2,0.1,1.0)]
freqs=[0.05,0.1,0.5,1.0,2.0,5.0,10.0,20.0,30.0,40.0]
for kind,N,a,b in cases:
    if kind=="lp": sos=signal.butter(N,a,'low',fs=fs,output='sos')
    elif kind=="hp": sos=signal.butter(N,a,'high',fs=fs,output='sos')
    else: sos=np.vstack([signal.butter(N,a,'high',fs=fs,output='sos'),signal.butter(N,b,'low',fs=fs,output='sos')])
    w,h=signal.sosfreqz(sos,worN=freqs,fs=fs)
    print(kind,N,a,b,"["+", ".join("%.10f"%v for v in np.abs(h))+"]")
# filtfilt reference: deterministic input
t=np.arange(2000)/fs
x=np.sin(2*np.pi*1.3*t)+0.5*np.sin(2*np.pi*12*t)+0.2*np.cos(2*np.pi*0.2*t)+0.01*t
sos=np.vstack([signal.butter(2,5.0,'high',fs=fs,output='sos'),signal.butter(2,30.0,'low',fs=fs,output='sos')])
y=signal.sosfiltfilt(sos,x,padlen=60)
idx=[500,777,1000,1234,1500]
print("ff idx",idx,"["+", ".join("%.10f"%y[i] for i in idx)+"]")
