document.addEventListener('DOMContentLoaded', () => {
    const streamList = document.getElementById('stream-list');

    function analyzeAndDisplayStreams() {
        fetch('/analysis_data.json')
            .then(response => {
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                return response.json();
            })
            .then(data => {
                streamList.innerHTML = '';
                const streamsWithHands = [];

                // Loop through each stream in the data object
                for (const streamName in data) {
                    const results = data[streamName];
                    if (!Array.isArray(results) || results.length < 5) {
                        continue; // Skip if not an array or not enough samples
                    }

                    const totalSamples = results.length;
                    const handsDetectedCount = results.filter(r => 
                        r && r.result && ['Left', 'Right', 'Both'].includes(r.result)
                    ).length;

                    // If more than half of the samples show hands, add it to our list
                    if (handsDetectedCount * 2 > totalSamples) {
                        streamsWithHands.push({
                            user_name: streamName,
                            url: `https://www.twitch.tv/${streamName}`
                        });
                    }
                }

                if (streamsWithHands.length > 0) {
                    streamsWithHands.forEach(stream => {
                        const listItem = document.createElement('li');
                        const link = document.createElement('a');
                        link.href = stream.url;
                        link.textContent = stream.user_name;
                        link.target = '_blank';
                        listItem.appendChild(link);
                        streamList.appendChild(listItem);
                    });
                } else {
                    const listItem = document.createElement('li');
                    listItem.textContent = 'No streams with hands detected at the moment.';
                    streamList.appendChild(listItem);
                }
            })
            .catch(error => {
                console.error('Error fetching or processing stream data:', error);
                streamList.innerHTML = '<li>Error loading or analyzing stream data.</li>';
            });
    }

    analyzeAndDisplayStreams();
    setInterval(analyzeAndDisplayStreams, 15000); // Refresh every 15 seconds
});