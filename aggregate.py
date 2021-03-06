#!/usr/bin/python3

import sys
import os
import csv
import argparse
import scipy.stats
import numpy as np
import math

from agg_setup import group_tests, get_paired, preprocess_samples

def percent_speedup_ref_denom(test_res, ref_res):
    return '%.2f' % ((ref_res - test_res) / (1.0 * ref_res) * 100)


def percent_speedup_test_denom(test_res, ref_res):
    return '%.2f' % ((ref_res - test_res) / (1.0 * test_res) * 100)

# calculate 0.95 confidence interval (ci[0] and ci[1]), assuming T-student distribution
def t_ci(samples):
    samples_mean = np.average(samples)
    standard_deviation = np.std(samples, ddof=1)
    t_bounds = scipy.stats.t.interval(0.95, len(samples) - 1)
    ci = [samples_mean + crit_val * standard_deviation / math.sqrt(len(samples))
              for crit_val in t_bounds]
    return ci


# read samples in res/tname/exectime.txt, assumes we are in res/
# returns, well, numpy array, not usual list
def get_samples(tname):
    et_path = os.path.join(tname, 'exectime.txt')
    assert os.path.isfile(et_path)
    return np.loadtxt(et_path)


# Process pair of tests test_name and reftest_name, assumes we are in res/ dir.
def process_pair(csvwriter, test_name, reftest_name, percent_speedup_func):
    csvrow = [test_name]
    test_samples = preprocess_samples(get_samples(test_name))
    reftest_samples = preprocess_samples(get_samples(reftest_name))

    t_median, r_median = np.median(test_samples), np.median(reftest_samples)
    csvrow.extend([t_median, r_median, percent_speedup_func(t_median, r_median)])

    t_min, r_min = np.min(test_samples), np.min(reftest_samples)
    csvrow.extend([t_min, r_min, percent_speedup_func(t_min, r_min)])

    t_avg, r_avg = np.average(test_samples), np.average(reftest_samples)
    test_ci, ref_ci = t_ci(test_samples), t_ci(reftest_samples)

    csvrow.extend([t_avg, "{0:.2f}, {1:.2f}\n".format(test_ci[0], test_ci[1]),
                   r_avg, "{0:.2f}, {1:.2f}\n".format(ref_ci[0], ref_ci[1]),
                   percent_speedup_func(t_avg, r_avg)])

    csvwriter.writerow(csvrow)


def aggregate(percent_speedup_func, resdir):
    if not os.path.isdir('res'):
        print('res directory not found')
        sys.exit(1)
    os.chdir(resdir)

    with open('res.csv', 'w', newline='') as csvfile:
        csvwriter = csv.writer(csvfile, delimiter='\t')
        header = ['test name',
                  'test median', 'ref median', '% speedup median',
                  'test min', 'ref min', '% speedup min',
                  'test avg', 'test 0.95 CI', 'ref avg', 'ref 0.95 CI', '% speedup avg']
        csvwriter.writerow(header)
        tests = next(os.walk('.'))[1]  # list of dirs in res/
        test_groups = group_tests(tests)
        for test_group in test_groups:
            print("\nProcessing new group")
            test_group.sort()
            for test_name in test_group:
                 reftest_name = get_paired(test_name)
                 if os.path.isdir(reftest_name):
                     print("Processing pair {0} - {1}".format(test_name, reftest_name))
                     process_pair(csvwriter, test_name, reftest_name,
                                  percent_speedup_func)
            csvwriter.writerow([])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="""
    Quick-and-dirty script to calc some stats after using run.py.
    Run it from project root directory, it will put res.csv to the directory
    with results.  file with results there. group_tests and get_paired funcs are
    kind of parameters, the first selects tests to analyze and groups them, the
    second tells how to find pairs for them. Define them in agg_setup.py,see
    agg_setup.py.example for example.
    """)
    parser.add_argument('-d', default='rd',
                        help="""
                        While calculating speedups in %%, reference value in
                        denom (rd, default) or test value, otherwise
                        """)
    parser.add_argument('-r', default='res',
                        help="""
                        Directory with results, 'res' is default
                        """)
    args = parser.parse_args()
    if args.d == 'rd':
        percent_speedup_func = percent_speedup_ref_denom
    else:
        percent_speedup_func = percent_speedup_test_denom
    aggregate(percent_speedup_func, args.r)
