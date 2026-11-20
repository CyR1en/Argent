"""Kernel L truth and Lightroom parity, using the unchanged LC3 chart readers."""
import json
from pathlib import Path
import subprocess
import tempfile

import numpy as np

# Lightroom interprets the chart numbers as camera RGB. Match InHouseColor.cameraToWorking;
# its common row sum keeps chart white at 1.
CAMERA_2020 = np.array([[1.121206,.023553,-.146545],[-.042143,1.481152,-.440795],
                        [.005260,-.238506,1.231460]], np.float32) / np.float32(.998214)
PROPHOTO = np.array([[.8352,.0489,.1159],[.0540,.9289,.0171],[-.0023,.0363,.9660]], np.float32)

# Measured shortfalls of section 0f's Python reference against Lightroom, in the same
# camera chart and dark-side scene measure used below. Frozen independently of the shader.
# Columns: Purple 1, 2, 5, 10, 20, Green 10. Zero means no shortfall.
EDGE_GAPS = {
    f'{state}/{name}': gap
    for name, values in {
        'neutral': (0.187424, 0.291163, 0.038749, 0.054014, 0.026986, 0.005867),
        'sky': (0, 0, 0.081843, 0.152026, 0.218688, 0),
        'foliage': (0.319345, 0.212346, 0, 0, 0, 0.319345),
        'brown': (0.922253, 0.599565, 0, 0, 0, 0),
        'brown-sky': (0.485557, 0.53984, 0.015567, 0.003686, 0, 0),
        'wide': (0.069925, 0.143593, 0.329987, 0.065807, 0.069915, 0.001251),
        'narrow': (0.156817, 0.004465, 0, 0, 0, 0.033495),
        'slant-22p5': (0.196926, 0.369715, 0.006473, 0.046246, 0.025978, 0.00695),
        'slant-45': (0.215604, 0.361225, 0, 0.03654, 0.020691, 0.008636),
        'line-4': (0.240719, 0, 0.023091, 0.006929, 0, 0.039529),
        'line-12': (0.142276, 0.197192, 0.122183, 0.112654, 0.059767, 0.007593),
        'swapped': (0, 0.000323, 0.000175, 0, 0.000369, 0),
    }.items()
    for state, gap in zip(['purple-amount-01','purple-amount-02','purple-amount-05',
                           'purple-amount-10','purple-amount-20','green-amount-10'], values)
}


def bracket_distance(a, b):
    """Largest boundary separation, ignoring differences within a sampled bracket."""
    a0 = a[0]
    a1 = a0 + (a[1]-a0) % 360
    return min(max(0, a0-(b[0]+turn+(b[1]-b[0])%360), b[0]+turn-a1) for turn in (-360,0,360))


def run(args):
    import lightroom_fields as fields
    import make_lens_charts as charts
    root = Path(__file__).resolve().parents[2]
    stock = root/'build/stocks/kodak-portra-400'
    truth, parity = [], []
    print('PARITY protected/non-plateau: KNOWN The half-chroma measure is a threshold; '
          'near half strength at window edges, a small strength difference flips the rim share. '
          'Only Purple 315..35 and Green 180..220 are gated.',flush=True)

    def report(group, name, ok, **values):
        if ok is not None: (truth if group == 'TRUTH' else parity).append(bool(ok))
        print(f'{group} {name}: {"INFO" if ok is None else "PASS" if ok else "FAIL"} '
              + json.dumps(values, sort_keys=True, allow_nan=False), flush=True)

    def lr_rows(kind, state, layout):
        if args.lightroom is None:
            return None
        filename = f'wheel-{state}.defringe.json' if kind == 'wheel' else f'edges-{state}.json'
        path = args.lightroom/filename
        if path.is_file():
            data = json.loads(path.read_text())
            return data if kind == 'wheel' else data['stimuli']
        paths = sorted(args.lightroom.glob(f'*_{state}.tif'))
        off = sorted(args.lightroom.glob('*_off.tif'))
        if not paths or not off:
            raise ValueError(f'missing Lightroom lane {kind}/{state}')
        a, b = fields.linear(off[0]), fields.linear(paths[0])
        return fields.defringe(a,b,layout) if kind == 'wheel' else fields.blurred_response(a,b,layout)

    with tempfile.TemporaryDirectory(prefix='argent-lc8-scorecard-') as directory:
        work = Path(directory)
        config = work/'identity.json'
        config.write_text(json.dumps({k:[1,1] for k in ('red','green','blue','gain')}))
        source, output = work/'input.npy', work/'output.npy'
        counter = 0

        def develop(settings, inject=True):
            nonlocal counter
            counter += 1
            command = [str(args.spike.resolve()),str(args.sample.resolve()),'--stock',str(stock),'--scale','1',
                       '--no-lens','--no-warmup','--lens-stage',str(config),'--defringe',settings,
                       '--scene-out',str(output),'--out',str(work/'print')]
            if inject: command += ['--scene-in',str(source)]
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode: raise RuntimeError(f'spike develop {counter} failed (exit {result.returncode})')
            if settings != 'default' and 'defringe  ' not in result.stdout:
                raise RuntimeError('spike did not execute Defringe')
            image = np.load(output, mmap_mode='r')
            if image.shape != (4672,7008,3): raise ValueError('sample must decode at scale 1 to 7008 by 4672')
            return image

        develop('default', inject=False)
        layouts = list(args.chart.glob('fringe-*-layout.json'))
        if not layouts: raise ValueError('--chart must contain fringe-wheel-layout.json or fringe-edges-layout.json')
        for layout_path in sorted(layouts):
            layout = json.loads(layout_path.read_text())
            kind = 'edges' if 'stimuli' in layout else 'wheel'
            rgb, generated = charts.blurred_edges() if kind == 'edges' else charts.fringe(hue_step=5)
            if generated != layout: raise ValueError('chart layout differs from LC3 generator')
            np.save(source, rgb @ CAMERA_2020.T)
            del rgb
            off = np.array(develop('default'))
            off_pp = off @ PROPHOTO.T

            def response(settings):
                image = np.array(develop(settings))
                pp = image @ PROPHOTO.T
                rows = fields.defringe(off_pp,pp,layout) if kind == 'wheel' else fields.blurred_response(off_pp,pp,layout)
                return image, rows

            if kind == 'wheel':
                def area(rows, hue, width):
                    return float(np.mean([r['area_fraction_removed'] for r in rows if r['kind']=='fringe'
                                          and r['hue_degrees']==hue and r['fringe_width_px']==width]))
                for colour,hue in [('purple',0),('green',180)]:
                    for amount in [1,2,5,10,20]:
                        state = f'{colour}-amount-{amount:02}'
                        image, rows = response(f'defringe-{colour}={amount}')
                        lr = lr_rows(kind,state,layout)
                        for width in [2,6,12]:
                            value = area(rows,hue,width)
                            if amount == 10: report('TRUTH',f'wheel/{colour}/{width}px',value>=.75,removed=value,minimum=.75)
                            target = area(lr,hue,width) if lr is not None else None
                            gated = colour=='green' or amount>=2
                            ok = (value>=target-.05 if colour=='green' else abs(value-target)<=.05) if gated and target is not None else None
                            report('PARITY',f'wheel/{state}/{width}px',ok,argent=value,lightroom=target,gated=gated,
                                   rule='at-least-lightroom-minus-.05' if colour=='green' else 'within-.05')
                        if amount == 10:
                            for i,r in enumerate(rows):
                                if r['kind']!='protected': continue
                                target = lr[i]['pixels_losing_half_chroma'] if lr is not None else None
                                value = r['pixels_losing_half_chroma']
                                hue = r['hue_degrees']
                                gated = (hue>=315 or hue<=35) if colour=='purple' else 180<=hue<=220
                                name = f'protected/{colour}/{hue}/{r["fringe_width_px"]}px'
                                if gated:
                                    report('PARITY',name,abs(value-target)<=.05 if target is not None else None,
                                           argent=value,lightroom=target,gated=True)
                                else:
                                    print(f'PARITY {name}: KNOWN '
                                          + json.dumps(dict(argent=value,lightroom=target,gated=False),sort_keys=True),flush=True)
                        del image
                    for end in ['lo','hi']:
                        for handle in [20,40,60,80]:
                            low,high = (handle,100) if end=='lo' else (0,handle)
                            state = f'{colour}-hue-{end}-{handle:03}'
                            image,rows = response(f'defringe-{colour}=20,defringe-{colour}-hue={low}:{high}')
                            lr = lr_rows(kind,state,layout)
                            got = fields.hue_response(rows)
                            target = fields.hue_response(lr) if lr is not None else None
                            if target is not None:
                                ga,ta=got.get('intervals',[]),target.get('intervals',[])
                                for boundary in ['start_bracket','end_bracket']:
                                    error = max((min(bracket_distance(a[boundary],b[boundary]) for b in ta) for a in ga),default=360) if ta else 360
                                    report('PARITY',f'hue/{state}/{boundary}',len(ga)==len(ta) and error<=5,
                                           argent=[a[boundary] for a in ga],lightroom=[b[boundary] for b in ta],distance=error,maximum=5)
                            del image
            else:
                for colour,amounts in [('purple',[1,2,5,10,20]),('green',[1,2,5,10,20])]:
                    for amount in amounts:
                        state=f'{colour}-amount-{amount:02}'
                        image,rows=response(f'defringe-{colour}={amount}')
                        lr=lr_rows(kind,state,layout) if colour=='purple' or amount==10 else None
                        for i,r in enumerate(rows):
                            name=r['stimulus']['name']
                            # The chart's purple fringe and its swapped green fringe are both dark-side stimuli.
                            # Keep that side when testing the opposite colour as well.
                            side='dark'
                            value=r['area'][side]['fraction_removed']
                            target=lr[i]['area'][side]['fraction_removed'] if lr is not None else None
                            gap = EDGE_GAPS[f'{state}/{name}'] if target is not None else None
                            if gap is not None:
                                print(f'PARITY edges/{state}/{name}/gap: KNOWN '
                                      + json.dumps(dict(measured_gap=gap,allowance=.03),sort_keys=True),flush=True)
                            minimum = target-gap-.03 if target is not None else None
                            report('PARITY',f'edges/{state}/{name}',value>=minimum if minimum is not None else None,
                                   argent=value,lightroom=target,gated=target is not None,side=side,
                                   measured_gap=gap,allowance=.03,minimum=minimum)
                            shift=max(map(abs,r['edge_shift_px']),default=0.)
                            report('TRUTH',f'edge-position/{state}/{name}',bool(r['edge_shift_px']) and shift<.1,shift_px=shift,maximum=.1)
                        del image
                # HDR step: the same Gaussian formula as LC3, at the contract's 2.0 highlight.
                rgb, hdr_layout=charts.blurred_edges()
                s=hdr_layout['stimuli'][0]; x0,y0,x1,y1=s['box']
                rgb[y0:y1,x0:x1]=.02+(rgb[y0:y1,x0:x1]-.02)*(2-.02)/(.9-.02)
                np.save(source,rgb@CAMERA_2020.T); del rgb
                hdr_off=np.array(develop('default')); hdr_on=np.array(develop('defringe-purple=10'))
                row=fields.blurred_response(hdr_off@PROPHOTO.T,hdr_on@PROPHOTO.T,hdr_layout)[0]
                value=row['area']['dark']['fraction_removed']
                report('TRUTH','HDR-purple-10',value>=.75,removed=value,minimum=.75)
                del hdr_off,hdr_on
            del off,off_pp
    if args.lightroom is None: report('PARITY','Lightroom-required',False,reason='no --lightroom lane files')
    print(f'TRUTH {"PASS" if all(truth) else "FAIL"}: {sum(truth)}/{len(truth)} gates',flush=True)
    print(f'PARITY {"PASS" if all(parity) else "FAIL"}: {sum(parity)}/{len(parity)} gates (INFO rows are not gates)',flush=True)
    return 0 if all(truth) and all(parity) else 1
