#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# The Original Code is Copyright (C) 2001-2002 by NaN Holding BV.
# All rights reserved.
#
# The Original Code is: some of this file.
#
#
# The code below is taken from Blender: https://developer.blender.org/diffusion/B/browse/master/source/blender/blenlib/intern/math_color.c

def blackbody_temperature_to_rgb(temperature):
    if temperature >= 12000.0:
        return [0.826270103, 0.994478524, 1.56626022]
    elif temperature < 965.0:
        return [4.70366907, 0.0, 0.0]
    else:
        if temperature >= 6365.0:
            i = 5
        elif temperature >= 3315.0:
            i = 4
        elif temperature >= 1902.0:
            i = 3
        elif temperature >= 1449.0:
            i = 2
        elif temperature >= 1167.0:
            i = 1
        else:
            i = 0

    blackbody_table_r = [
        [2.52432244e+03, -1.06185848e-03, 3.11067539e+00],
        [3.37763626e+03, -4.34581697e-04, 1.64843306e+00],
        [4.10671449e+03, -8.61949938e-05, 6.41423749e-01],
        [4.66849800e+03, 2.85655028e-05, 1.29075375e-01],
        [4.60124770e+03, 2.89727618e-05, 1.48001316e-01],
        [3.78765709e+03, 9.36026367e-06, 3.98995841e-01]
    ]

    blackbody_table_g = [
        [-7.50343014e+02, 3.15679613e-04, 4.73464526e-01],
        [-1.00402363e+03, 1.29189794e-04, 9.08181524e-01],
        [-1.22075471e+03, 2.56245413e-05, 1.20753416e+00],
        [-1.42546105e+03, -4.01730887e-05, 1.44002695e+00],
        [-1.18134453e+03, -2.18913373e-05, 1.30656109e+00],
        [-5.00279505e+02, -4.59745390e-06, 1.09090465e+00]
    ]

    blackbody_table_b = [
        [0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
        [-2.02524603e-11, 1.79435860e-07, -2.60561875e-04, -1.41761141e-02],
        [-2.22463426e-13, -1.55078698e-08, 3.81675160e-04, -7.30646033e-01],
        [6.72595954e-13, -2.73059993e-08, 4.24068546e-04, -7.52204323e-01]
    ]

    r = blackbody_table_r[i];
    g = blackbody_table_g[i];
    b = blackbody_table_b[i];

    t_inv = 1.0 / temperature;
    return [r[0] * t_inv + r[1] * temperature + r[2],
            g[0] * t_inv + g[1] * temperature + g[2],
            ((b[0] * temperature + b[1]) * temperature + b[2]) * temperature + b[3]]

#import colour
#
#def blackbody_temperature_to_rgb(temperature):
#	xy = colour.CCT_to_xy(temperature)
#	XYZ = colour.xy_to_XYZ(xy)
#	RGB = colour.XYZ_to_RGB(XYZ)
#	return float3(RGB[0], RGB[1], RGB[2])
