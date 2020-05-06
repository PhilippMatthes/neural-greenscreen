const tf = require('@tensorflow/tfjs-node');
const bodyPix = require('@tensorflow-models/body-pix');
const https = require('https');
const url = require('url');
const fs = require('fs');
(async () => {
    const net = await bodyPix.load({
        architecture: 'MobileNetV1',
        outputStride: 16,
        multiplier: 0.75,
        quantBytes: 2,
    });
    const server = https.createServer({
        key: fs.readFileSync('server.key'),
        cert: fs.readFileSync('server.crt')
    });
    server.on('request', async (req, res) => {
        var request = url.parse(req.url, true);
        var action = request.pathname;

        if (action === '/mask') {
            var chunks = [];
            req.on('data', (chunk) => {
                chunks.push(chunk);
            });
            req.on('end', async () => {
                const image = tf.node.decodeImage(Buffer.concat(chunks));
                segmentation = await net.segmentPerson(image, {
                    flipHorizontal: false,
                    internalResolution: 'medium',
                    segmentationThreshold: 0.7,
                });
                res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
                res.write(Buffer.from(segmentation.data));
                res.end();
                tf.dispose(image);
            });
        }

        if (action === '/background') {
            var img = fs.readFileSync('./background.jpg');
            res.writeHead(200, {'Content-Type': 'image/jpeg' });
            res.end(img, 'binary');
        }
    });
    server.listen(9000);
})();
